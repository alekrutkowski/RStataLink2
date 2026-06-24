#include "stplugin.h"

#include <nng/nng.h>
#include <nng/protocol/pair0/pair.h>
#include <nng/protocol/reqrep0/rep.h>
#include <nng/transport/inproc/inproc.h>
#include <nng/transport/ipc/ipc.h>
#include <nng/transport/tcp/tcp.h>

#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RSLNG_HEADER_SIZE 24u
#define RSLNG_DF_HEADER_SIZE 12u
#define RSLNG_NA_STRLEN 2147483647u
#define RSLNG_MAX_STR 2045u

#define MSG_PING 1u
#define MSG_EXEC 2u
#define MSG_PUT_DF 3u
#define MSG_GET_DF 4u
#define MSG_STOP 5u
#define MSG_GET_RESULTS 6u
#define MSG_EXEC_NOLOG 7u
#define MSG_EXEC_NOSNAP 8u
#define MSG_EXEC_NOLOG_NOSNAP 9u
#define MSG_OK 100u
#define MSG_ERR 101u
#define MSG_DATA 102u
#define MSG_TIMEOUT 103u

static const unsigned char RSLNG_MAGIC[8] = {'R','S','L','N','G','0','1','\0'};
static const unsigned char RSLNG_DF_MAGIC[4] = {'D','F','0','2'};
static const unsigned char RSLNG_DF_MAGIC_V1[4] = {'D','F','0','1'};

static nng_socket g_sock;
static int g_open = 0;
static int g_tcp_reg = -1;
static int g_ipc_reg = -1;
static int g_inproc_reg = -1;
static unsigned char *g_last = NULL;
static size_t g_last_len = 0;
static char *g_last_text = NULL;
static const unsigned char *g_last_payload = NULL;
static size_t g_last_payload_len = 0;
static uint32_t g_last_kind = 0;

typedef struct {
    unsigned char *data;
    size_t len;
    size_t cap;
} rslng_buf;

typedef struct {
    uint32_t type;
    uint32_t width;
    char *name;
} rslng_col;

typedef struct {
    uint32_t nrows;
    uint32_t ncols;
    rslng_col *cols;
    int has_widths;
    const unsigned char *data;
    size_t data_len;
} rslng_df;

static uint32_t get_u32(const unsigned char *p) {
    return ((uint32_t)p[0]) |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static void put_u32_raw(unsigned char *p, uint32_t x) {
    p[0] = (unsigned char)(x & 0xffu);
    p[1] = (unsigned char)((x >> 8) & 0xffu);
    p[2] = (unsigned char)((x >> 16) & 0xffu);
    p[3] = (unsigned char)((x >> 24) & 0xffu);
}

static double get_double_le(const unsigned char *p) {
    uint64_t u = ((uint64_t)p[0]) |
                 ((uint64_t)p[1] << 8) |
                 ((uint64_t)p[2] << 16) |
                 ((uint64_t)p[3] << 24) |
                 ((uint64_t)p[4] << 32) |
                 ((uint64_t)p[5] << 40) |
                 ((uint64_t)p[6] << 48) |
                 ((uint64_t)p[7] << 56);
    double d;
    memcpy(&d, &u, 8);
    return d;
}

static void put_double_raw(unsigned char *p, double d) {
    uint64_t u;
    memcpy(&u, &d, 8);
    p[0] = (unsigned char)(u & 0xffu);
    p[1] = (unsigned char)((u >> 8) & 0xffu);
    p[2] = (unsigned char)((u >> 16) & 0xffu);
    p[3] = (unsigned char)((u >> 24) & 0xffu);
    p[4] = (unsigned char)((u >> 32) & 0xffu);
    p[5] = (unsigned char)((u >> 40) & 0xffu);
    p[6] = (unsigned char)((u >> 48) & 0xffu);
    p[7] = (unsigned char)((u >> 56) & 0xffu);
}

static const char *kind_name(uint32_t kind) {
    switch (kind) {
    case MSG_PING: return "PING";
    case MSG_EXEC: return "EXEC";
    case MSG_EXEC_NOLOG: return "EXEC_NOLOG";
    case MSG_EXEC_NOSNAP: return "EXEC_NOSNAP";
    case MSG_EXEC_NOLOG_NOSNAP: return "EXEC_NOLOG_NOSNAP";
    case MSG_PUT_DF: return "PUT_DF";
    case MSG_GET_DF: return "GET_DF";
    case MSG_STOP: return "STOP";
    case MSG_GET_RESULTS: return "GET_RESULTS";
    case MSG_OK: return "OK";
    case MSG_ERR: return "ERR";
    case MSG_DATA: return "DATA";
    case MSG_TIMEOUT: return "TIMEOUT";
    default: return "UNKNOWN";
    }
}

static int fail_msg(const char *msg) {
    SF_error((char *)msg);
    SF_error("\n");
    return 459;
}

static int fail_nng(const char *where, int rv) {
    char buf[512];
    snprintf(buf, sizeof(buf), "RStataLink2 NNG error in %s: %s", where, nng_strerror(rv));
    return fail_msg(buf);
}

static int fail_nng_endpoint(const char *where, int rv, const char *endpoint) {
    char buf[768];
    snprintf(buf, sizeof(buf), "RStataLink2 NNG error in %s for endpoint '%s': %s",
             where, endpoint ? endpoint : "", nng_strerror(rv));
    return fail_msg(buf);
}

static int endpoint_has_scheme(const char *endpoint, const char *scheme) {
    size_t n;
    if (endpoint == NULL || scheme == NULL) return 0;
    n = strlen(scheme);
    return strncmp(endpoint, scheme, n) == 0;
}

static int register_tcp_once(void) {
    if (g_tcp_reg < 0) g_tcp_reg = nng_tcp_register();
    return g_tcp_reg;
}

static int register_ipc_once(void) {
    if (g_ipc_reg < 0) g_ipc_reg = nng_ipc_register();
    return g_ipc_reg;
}

static int register_inproc_once(void) {
    if (g_inproc_reg < 0) g_inproc_reg = nng_inproc_register();
    return g_inproc_reg;
}

static int register_endpoint_transport(const char *endpoint) {
    int rv = 0;
    int used = 0;
    char buf[768];

    /*
       Explicit registration is important for static NNG builds.  It also
       creates a direct symbol reference so static linkers keep the transport
       object code in the Stata plugin.  Newer NNG documentation says explicit
       registration is generally no longer needed, but it is harmless here and
       fixes static plugin builds where listen/dial would otherwise return
       NNG_ENOTSUP ("Not supported") for tcp:// endpoints.

       We do not fail immediately if a registration call returns non-zero,
       because some NNG builds may have already registered a transport. The
       following listen/dial call is the authoritative check.
    */
    if (endpoint_has_scheme(endpoint, "tcp://") ||
        endpoint_has_scheme(endpoint, "tcp4://") ||
        endpoint_has_scheme(endpoint, "tcp6://")) {
        rv = register_tcp_once();
        used = 1;
    } else if (endpoint_has_scheme(endpoint, "ipc://")) {
        rv = register_ipc_once();
        used = 1;
    } else if (endpoint_has_scheme(endpoint, "inproc://")) {
        rv = register_inproc_once();
        used = 1;
    }

    if (!used) return 0;
    if (rv == 0) return 0;

    snprintf(buf, sizeof(buf),
             "RStataLink2 could not register NNG transport for endpoint '%s': %s",
             endpoint ? endpoint : "", nng_strerror(rv));
    return fail_msg(buf);
}

static char *rslng_strdup(const char *s) {
    size_t n = strlen(s ? s : "");
    char *out = (char *)malloc(n + 1u);
    if (out == NULL) return NULL;
    memcpy(out, s ? s : "", n);
    out[n] = '\0';
    return out;
}

static char *rslng_clean_arg(const char *s) {
    const char *start;
    size_t n;
    char *out;

    start = s ? s : "";

    for (;;) {
        int changed = 0;
        while (*start && isspace((unsigned char)*start)) {
            start++;
            changed = 1;
        }
        n = strlen(start);
        while (n > 0u && isspace((unsigned char)start[n - 1u])) {
            n--;
            changed = 1;
        }

        /* Stata's string-as-is option and compound quoting can leave literal
           quote characters inside plugin arguments.  NNG endpoint schemes must
           start at byte 0 (for example tcp://), so strip repeated outer quote
           remnants defensively.  Internal quote characters are left untouched. */
        while (n > 0u && (start[0] == '"' || start[0] == '\'' || start[0] == '`')) {
            start++;
            n--;
            changed = 1;
        }
        while (n > 0u && (start[n - 1u] == '"' || start[n - 1u] == '\'' || start[n - 1u] == '`')) {
            n--;
            changed = 1;
        }

        if (!changed) break;
    }

    out = (char *)malloc(n + 1u);
    if (out == NULL) return NULL;
    memcpy(out, start, n);
    out[n] = '\0';
    return out;
}

static void clear_last(void) {
    if (g_last != NULL) {
        nng_free(g_last, g_last_len);
        g_last = NULL;
    }
    g_last_len = 0;
    if (g_last_text != NULL) {
        free(g_last_text);
        g_last_text = NULL;
    }
    g_last_payload = NULL;
    g_last_payload_len = 0;
    g_last_kind = 0;
}

static int save_local(const char *name, const char *value) {
    char mac[96];
    snprintf(mac, sizeof(mac), "_%s", name);
    return SF_macro_save(mac, (char *)(value ? value : ""));
}

static int buf_reserve(rslng_buf *b, size_t add) {
    size_t need = b->len + add;
    unsigned char *tmp;
    size_t cap;
    if (need <= b->cap) return 0;
    cap = b->cap ? b->cap : 1024u;
    while (cap < need) cap *= 2u;
    tmp = (unsigned char *)realloc(b->data, cap);
    if (tmp == NULL) return 1;
    b->data = tmp;
    b->cap = cap;
    return 0;
}

static int buf_append(rslng_buf *b, const void *src, size_t n) {
    if (n == 0) return 0;
    if (buf_reserve(b, n)) return 1;
    memcpy(b->data + b->len, src, n);
    b->len += n;
    return 0;
}

static int buf_u32(rslng_buf *b, uint32_t x) {
    unsigned char tmp[4];
    put_u32_raw(tmp, x);
    return buf_append(b, tmp, 4u);
}

static int buf_double(rslng_buf *b, double x) {
    unsigned char tmp[8];
    put_double_raw(tmp, x);
    return buf_append(b, tmp, 8u);
}

static void buf_free(rslng_buf *b) {
    if (b->data) free(b->data);
    b->data = NULL;
    b->len = b->cap = 0;
}

static int send_msg(uint32_t kind, const char *text, const unsigned char *payload, size_t payload_len) {
    unsigned char *msg;
    unsigned char *p;
    size_t text_len = text ? strlen(text) : 0u;
    size_t total = RSLNG_HEADER_SIZE + text_len + payload_len;
    int rv;
    if (!g_open) return fail_msg("RStataLink2 socket is not open");
    if (text_len > 2147483647u || payload_len > 2147483647u) {
        return fail_msg("RStataLink2 message exceeds 2 GB prototype limit");
    }
    msg = (unsigned char *)malloc(total ? total : 1u);
    if (msg == NULL) return fail_msg("RStataLink2 out of memory while building message");
    p = msg;
    memcpy(p, RSLNG_MAGIC, 8u); p += 8u;
    put_u32_raw(p, kind); p += 4u;
    put_u32_raw(p, (uint32_t)text_len); p += 4u;
    put_u32_raw(p, (uint32_t)payload_len); p += 4u;
    put_u32_raw(p, 0u); p += 4u;
    if (text_len) { memcpy(p, text, text_len); p += text_len; }
    if (payload_len) { memcpy(p, payload, payload_len); }
    rv = nng_send(g_sock, msg, total, 0);
    free(msg);
    if (rv != 0) return fail_nng("send", rv);
    return 0;
}

static int parse_last_header(void) {
    uint32_t text_len, payload_len;
    if (g_last_len < RSLNG_HEADER_SIZE) return fail_msg("RStataLink2 truncated message header");
    if (memcmp(g_last, RSLNG_MAGIC, 8u) != 0) return fail_msg("RStataLink2 bad message magic");
    g_last_kind = get_u32(g_last + 8u);
    text_len = get_u32(g_last + 12u);
    payload_len = get_u32(g_last + 16u);
    if ((size_t)RSLNG_HEADER_SIZE + text_len + payload_len > g_last_len) {
        return fail_msg("RStataLink2 truncated message body");
    }
    g_last_text = (char *)malloc((size_t)text_len + 1u);
    if (g_last_text == NULL) return fail_msg("RStataLink2 out of memory for text");
    if (text_len) memcpy(g_last_text, g_last + RSLNG_HEADER_SIZE, text_len);
    g_last_text[text_len] = '\0';
    g_last_payload = g_last + RSLNG_HEADER_SIZE + text_len;
    g_last_payload_len = payload_len;
    return 0;
}

static void df_free(rslng_df *df) {
    uint32_t i;
    if (df->cols != NULL) {
        for (i = 0u; i < df->ncols; i++) {
            if (df->cols[i].name != NULL) free(df->cols[i].name);
        }
        free(df->cols);
    }
    memset(df, 0, sizeof(*df));
}

static int parse_df(rslng_df *df) {
    const unsigned char *p = g_last_payload;
    size_t left = g_last_payload_len;
    uint32_t i, namelen;
    memset(df, 0, sizeof(*df));
    if (left < RSLNG_DF_HEADER_SIZE) return fail_msg("RStataLink2 truncated data-frame payload");
    if (memcmp(p, RSLNG_DF_MAGIC, 4u) == 0) {
        df->has_widths = 1;
    } else if (memcmp(p, RSLNG_DF_MAGIC_V1, 4u) == 0) {
        df->has_widths = 0;
    } else {
        return fail_msg("RStataLink2 bad data-frame magic");
    }
    df->nrows = get_u32(p + 4u);
    df->ncols = get_u32(p + 8u);
    p += RSLNG_DF_HEADER_SIZE;
    left -= RSLNG_DF_HEADER_SIZE;
    if (df->ncols > 0u) {
        df->cols = (rslng_col *)calloc(df->ncols, sizeof(rslng_col));
        if (df->cols == NULL) return fail_msg("RStataLink2 out of memory for metadata");
    }
    for (i = 0u; i < df->ncols; i++) {
        size_t meta_need = df->has_widths ? 12u : 8u;
        if (left < meta_need) { df_free(df); return fail_msg("RStataLink2 truncated column metadata"); }
        df->cols[i].type = get_u32(p); p += 4u;
        if (df->has_widths) { df->cols[i].width = get_u32(p); p += 4u; }
        else df->cols[i].width = 0u;
        namelen = get_u32(p); p += 4u;
        left -= meta_need;
        if (left < namelen) { df_free(df); return fail_msg("RStataLink2 truncated column name"); }
        df->cols[i].name = (char *)malloc((size_t)namelen + 1u);
        if (df->cols[i].name == NULL) { df_free(df); return fail_msg("RStataLink2 out of memory for column name"); }
        memcpy(df->cols[i].name, p, namelen);
        df->cols[i].name[namelen] = '\0';
        p += namelen;
        left -= namelen;
    }
    df->data = p;
    df->data_len = left;
    return 0;
}

static int action_open(int argc, char *argv[]) {
    char *endpoint = NULL, *protocol = NULL, *mode = NULL, *timeout_s = NULL;
    int rv, timeout, out = 0;
    if (argc < 5) return 198;

    endpoint = rslng_clean_arg(argv[1]);
    protocol = rslng_clean_arg(argv[2]);
    mode = rslng_clean_arg(argv[3]);
    timeout_s = rslng_clean_arg(argv[4]);
    if (endpoint == NULL || protocol == NULL || mode == NULL || timeout_s == NULL) {
        out = fail_msg("RStataLink2 out of memory while parsing plugin arguments");
        goto done;
    }
    timeout = atoi(timeout_s);

    if (g_open) {
        nng_close(g_sock);
        g_open = 0;
    }
    if (strcmp(protocol, "rep") == 0) {
        rv = nng_rep0_open(&g_sock);
    } else if (strcmp(protocol, "pair") == 0) {
        rv = nng_pair0_open(&g_sock);
    } else {
        out = fail_msg("RStataLink2 unknown protocol; expected rep or pair");
        goto done;
    }
    if (rv != 0) {
        out = fail_nng("open", rv);
        goto done;
    }
    if (!endpoint_has_scheme(endpoint, "tcp://") &&
        !endpoint_has_scheme(endpoint, "tcp4://") &&
        !endpoint_has_scheme(endpoint, "tcp6://") &&
        !endpoint_has_scheme(endpoint, "ipc://") &&
        !endpoint_has_scheme(endpoint, "inproc://")) {
        out = fail_nng_endpoint("endpoint parse", NNG_ENOTSUP, endpoint);
        nng_close(g_sock);
        goto done;
    }
    out = register_endpoint_transport(endpoint);
    if (out != 0) {
        nng_close(g_sock);
        goto done;
    }
    if (timeout > 0) {
        nng_socket_set_ms(g_sock, NNG_OPT_RECVTIMEO, timeout);
        nng_socket_set_ms(g_sock, NNG_OPT_SENDTIMEO, timeout);
    }
    if (strcmp(mode, "listen") == 0) {
        rv = nng_listen(g_sock, endpoint, NULL, 0);
    } else if (strcmp(mode, "dial") == 0) {
        rv = nng_dial(g_sock, endpoint, NULL, 0);
    } else {
        nng_close(g_sock);
        out = fail_msg("RStataLink2 unknown socket mode; expected listen or dial");
        goto done;
    }
    if (rv != 0) {
        nng_close(g_sock);
        out = fail_nng_endpoint("listen/dial", rv, endpoint);
        goto done;
    }
    g_open = 1;
    out = 0;

done:
    if (endpoint) free(endpoint);
    if (protocol) free(protocol);
    if (mode) free(mode);
    if (timeout_s) free(timeout_s);
    return out;
}

static int action_recv(void) {
    void *buf = NULL;
    size_t sz = 0u;
    int rv;
    if (!g_open) return fail_msg("RStataLink2 socket is not open");
    clear_last();
    rv = nng_recv(g_sock, &buf, &sz, NNG_FLAG_ALLOC);
    if (rv == NNG_ETIMEDOUT) {
        save_local("rslng_kind", "TIMEOUT");
        save_local("rslng_text", "");
        return 0;
    }
    if (rv != 0) return fail_nng("recv", rv);
    g_last = (unsigned char *)buf;
    g_last_len = sz;
    rv = parse_last_header();
    if (rv != 0) return rv;
    save_local("rslng_kind", kind_name(g_last_kind));
    save_local("rslng_text", g_last_text);
    return 0;
}

static int action_reply_text(int argc, char *argv[]) {
    int rc;
    const char *text;
    if (argc < 2) return 198;
    rc = atoi(argv[1]);
    text = argc >= 3 ? argv[2] : "";
    return send_msg(rc == 0 ? MSG_OK : MSG_ERR, text, NULL, 0u);
}

static int read_file_text(const char *path, char **out, size_t *out_len) {
    FILE *fp;
    char *buf = NULL;
    size_t len = 0u, cap = 8192u;

    if (out == NULL || out_len == NULL) return 1;
    *out = NULL;
    *out_len = 0u;
    if (path == NULL || path[0] == '\0') return 1;

    fp = fopen(path, "rb");
    if (fp == NULL) return 1;

    buf = (char *)malloc(cap + 1u);
    if (buf == NULL) {
        fclose(fp);
        return 1;
    }

    for (;;) {
        size_t got;
        if (len == cap) {
            size_t new_cap = cap * 2u;
            char *tmp;
            if (new_cap <= cap) {
                free(buf);
                fclose(fp);
                return 1;
            }
            tmp = (char *)realloc(buf, new_cap + 1u);
            if (tmp == NULL) {
                free(buf);
                fclose(fp);
                return 1;
            }
            buf = tmp;
            cap = new_cap;
        }
        got = fread(buf + len, 1u, cap - len, fp);
        len += got;
        if (got == 0u) break;
    }

    if (ferror(fp)) {
        free(buf);
        fclose(fp);
        return 1;
    }
    fclose(fp);
    buf[len] = '\0';
    *out = buf;
    *out_len = len;
    return 0;
}

static int action_reply_file(int argc, char *argv[]) {
    int rc, out;
    char *path = NULL;
    char *body = NULL;
    char *msg = NULL;
    size_t body_len = 0u, prefix_len, total;
    char prefix[64];

    if (argc < 3) return 198;
    rc = atoi(argv[1]);
    path = rslng_clean_arg(argv[2]);
    if (path == NULL) return fail_msg("RStataLink2 out of memory while parsing log path");

    if (read_file_text(path, &body, &body_len) != 0) {
        const char *fallback = "RStataLink2 could not read Stata log file.\n";
        body_len = strlen(fallback);
        body = (char *)malloc(body_len + 1u);
        if (body == NULL) {
            free(path);
            return fail_msg("RStataLink2 out of memory while reading log file");
        }
        memcpy(body, fallback, body_len + 1u);
    }

    snprintf(prefix, sizeof(prefix), "__RSL2_RC__=%d\n", rc);
    prefix_len = strlen(prefix);
    total = prefix_len + body_len;
    msg = (char *)malloc(total + 1u);
    if (msg == NULL) {
        free(path);
        free(body);
        return fail_msg("RStataLink2 out of memory while building log reply");
    }
    memcpy(msg, prefix, prefix_len);
    if (body_len) memcpy(msg + prefix_len, body, body_len);
    msg[total] = '\0';

    out = send_msg(rc == 0 ? MSG_OK : MSG_ERR, msg, NULL, 0u);
    free(path);
    free(body);
    free(msg);
    return out;
}

static int action_meta(void) {
    rslng_df df;
    const unsigned char *p;
    size_t left;
    uint32_t i, j, len, width;
    size_t names_cap, types_cap, widths_cap;
    char *names = NULL, *types = NULL, *widths = NULL;
    char tmp[64];
    int rc;
    if (g_last_kind != MSG_PUT_DF) return fail_msg("RStataLink2 last message is not PUT_DF");
    rc = parse_df(&df);
    if (rc != 0) return rc;
    names_cap = types_cap = widths_cap = (size_t)df.ncols * 40u + 32u;
    names = (char *)calloc(names_cap, 1u);
    types = (char *)calloc(types_cap, 1u);
    widths = (char *)calloc(widths_cap, 1u);
    if (!names || !types || !widths) {
        if (names) free(names);
        if (types) free(types);
        if (widths) free(widths);
        df_free(&df);
        return fail_msg("RStataLink2 out of memory for macros");
    }
    p = df.data;
    left = df.data_len;
    for (i = 0u; i < df.ncols; i++) {
        if (i) { strncat(names, " ", names_cap - strlen(names) - 1u); strncat(types, " ", types_cap - strlen(types) - 1u); strncat(widths, " ", widths_cap - strlen(widths) - 1u); }
        strncat(names, df.cols[i].name, names_cap - strlen(names) - 1u);
        if (df.cols[i].type == 1u) {
            if (!df.has_widths) {
                if (left < (size_t)df.nrows * 8u) { rc = fail_msg("RStataLink2 truncated numeric data"); goto done; }
                p += (size_t)df.nrows * 8u;
                left -= (size_t)df.nrows * 8u;
            }
            strncat(types, "num", types_cap - strlen(types) - 1u);
            strncat(widths, "0", widths_cap - strlen(widths) - 1u);
        } else if (df.cols[i].type == 2u) {
            if (df.has_widths) {
                width = df.cols[i].width;
                if (width < 1u) width = 1u;
                if (width > RSLNG_MAX_STR) width = RSLNG_MAX_STR;
            } else {
                width = 1u;
                for (j = 0u; j < df.nrows; j++) {
                    if (left < 4u) { rc = fail_msg("RStataLink2 truncated string length"); goto done; }
                    len = get_u32(p); p += 4u; left -= 4u;
                    if (len != RSLNG_NA_STRLEN) {
                        if (left < len) { rc = fail_msg("RStataLink2 truncated string data"); goto done; }
                        if (len > width) width = len;
                        p += len; left -= len;
                    }
                }
                if (width > RSLNG_MAX_STR) width = RSLNG_MAX_STR;
            }
            strncat(types, "str", types_cap - strlen(types) - 1u);
            snprintf(tmp, sizeof(tmp), "%u", width);
            strncat(widths, tmp, widths_cap - strlen(widths) - 1u);
        } else {
            rc = fail_msg("RStataLink2 unknown column type"); goto done;
        }
    }
    snprintf(tmp, sizeof(tmp), "%u", df.nrows); save_local("rslng_nrows", tmp);
    snprintf(tmp, sizeof(tmp), "%u", df.ncols); save_local("rslng_ncols", tmp);
    save_local("rslng_names", names);
    save_local("rslng_types", types);
    save_local("rslng_widths", widths);
    rc = 0;

done:
    free(names); free(types); free(widths);
    df_free(&df);
    return rc;
}

static int ensure_char_buffer(char **buf, size_t *cap, size_t need) {
    char *tmp;
    if (need <= *cap) return 0;
    tmp = (char *)realloc(*buf, need);
    if (tmp == NULL) return 1;
    *buf = tmp;
    *cap = need;
    return 0;
}

static int action_putdf(void) {
    rslng_df df;
    const unsigned char *p;
    size_t left, str_cap = 0u;
    char *str_buf = NULL;
    uint32_t i, j, len;
    ST_retcode rc;
    int prc;
    if (g_last_kind != MSG_PUT_DF) return fail_msg("RStataLink2 last message is not PUT_DF");
    prc = parse_df(&df);
    if (prc != 0) return prc;
    if ((uint32_t)SF_nvars() != df.ncols) { df_free(&df); return fail_msg("RStataLink2 varlist and payload column counts differ"); }
    if ((uint32_t)SF_nobs() < df.nrows) { df_free(&df); return fail_msg("RStataLink2 not enough Stata observations"); }
    p = df.data;
    left = df.data_len;
    for (i = 0u; i < df.ncols; i++) {
        ST_int vi = (ST_int)i + 1;
        if (df.cols[i].type == 1u) {
            if (SF_var_is_string(vi)) { free(str_buf); df_free(&df); return fail_msg("RStataLink2 numeric payload column mapped to string Stata variable"); }
            if (left < (size_t)df.nrows * 8u) { free(str_buf); df_free(&df); return fail_msg("RStataLink2 truncated numeric data"); }
            for (j = 0u; j < df.nrows; j++) {
                double val = get_double_le(p);
                p += 8u; left -= 8u;
                if (isnan(val)) val = SV_missval;
                rc = SF_vstore(vi, (ST_int)j + 1, val);
                if (rc) { free(str_buf); df_free(&df); return rc; }
            }
        } else if (df.cols[i].type == 2u) {
            if (!SF_var_is_string(vi)) { free(str_buf); df_free(&df); return fail_msg("RStataLink2 string payload column mapped to numeric Stata variable"); }
            for (j = 0u; j < df.nrows; j++) {
                uint32_t copy_len;
                if (left < 4u) { free(str_buf); df_free(&df); return fail_msg("RStataLink2 truncated string length"); }
                len = get_u32(p); p += 4u; left -= 4u;
                if (len == RSLNG_NA_STRLEN) len = 0u;
                if (left < len) { free(str_buf); df_free(&df); return fail_msg("RStataLink2 truncated string data"); }
                copy_len = len > RSLNG_MAX_STR ? RSLNG_MAX_STR : len;
                if (ensure_char_buffer(&str_buf, &str_cap, (size_t)copy_len + 1u)) {
                    free(str_buf); df_free(&df); return fail_msg("RStataLink2 out of memory for string buffer");
                }
                if (copy_len) memcpy(str_buf, p, copy_len);
                str_buf[copy_len] = '\0';
                rc = SF_sstore(vi, (ST_int)j + 1, str_buf);
                if (rc) { free(str_buf); df_free(&df); return rc; }
                p += len; left -= len;
            }
        } else {
            free(str_buf);
            df_free(&df);
            return fail_msg("RStataLink2 unknown column type");
        }
    }
    free(str_buf);
    df_free(&df);
    return 0;
}

static char **split_names(const char *s, int *n) {
    char *copy, *tok;
    char **out = NULL;
    int cap = 0, len = 0;
    copy = rslng_strdup(s ? s : "");
    if (copy == NULL) return NULL;
    tok = strtok(copy, " \t\r\n");
    while (tok != NULL) {
        if (len == cap) {
            char **tmp;
            cap = cap ? cap * 2 : 8;
            tmp = (char **)realloc(out, (size_t)cap * sizeof(char *));
            if (tmp == NULL) { free(copy); return out; }
            out = tmp;
        }
        out[len] = rslng_strdup(tok);
        if (out[len] == NULL) { free(copy); return out; }
        len++;
        tok = strtok(NULL, " \t\r\n");
    }
    free(copy);
    *n = len;
    return out;
}

static void split_names_free(char **x, int n) {
    int i;
    if (!x) return;
    for (i = 0; i < n; i++) if (x[i]) free(x[i]);
    free(x);
}

static int action_getdf(int argc, char *argv[]) {
    rslng_buf b = {0};
    char **names = NULL;
    int n_names = 0;
    ST_int nvars = SF_nvars();
    ST_int nobs = SF_nobs();
    ST_int i, j;
    ST_retcode rc;
    char default_name[40];
    char *str_buf = NULL;
    size_t str_cap = 0u;
    if (argc >= 2) names = split_names(argv[1], &n_names);
    if (buf_append(&b, RSLNG_DF_MAGIC_V1, 4u) || buf_u32(&b, (uint32_t)nobs) || buf_u32(&b, (uint32_t)nvars)) goto oom;
    for (i = 1; i <= nvars; i++) {
        const char *nm;
        uint32_t type = SF_var_is_string(i) ? 2u : 1u;
        if (i - 1 < n_names) nm = names[i - 1];
        else { snprintf(default_name, sizeof(default_name), "v%d", (int)i); nm = default_name; }
        if (buf_u32(&b, type) || buf_u32(&b, (uint32_t)strlen(nm)) || buf_append(&b, nm, strlen(nm))) goto oom;
    }
    for (i = 1; i <= nvars; i++) {
        if (!SF_var_is_string(i)) {
            for (j = 1; j <= nobs; j++) {
                double z;
                rc = SF_vdata(i, j, &z);
                if (rc) goto fail_rc;
                if (SF_is_missing(z)) z = NAN;
                if (buf_double(&b, z)) goto oom;
            }
        } else {
            for (j = 1; j <= nobs; j++) {
                int len, copied;
                if (SF_var_is_strl(i)) {
                    if (SF_var_is_binary(i, j)) {
                        free(str_buf); buf_free(&b); split_names_free(names, n_names);
                        return fail_msg("RStataLink2 does not export binary strL values yet");
                    }
                    len = SF_sdatalen(i, j);
                    if (len < 0) { free(str_buf); buf_free(&b); split_names_free(names, n_names); return fail_msg("RStataLink2 could not read strL length"); }
                    if (ensure_char_buffer(&str_buf, &str_cap, (size_t)len + 1u)) goto oom;
                    copied = SF_strldata(i, j, str_buf, len + 1);
                    if (copied < 0) { free(str_buf); buf_free(&b); split_names_free(names, n_names); return fail_msg("RStataLink2 could not read strL value"); }
                    str_buf[copied] = '\0';
                    if (buf_u32(&b, (uint32_t)copied) || buf_append(&b, str_buf, (size_t)copied)) goto oom;
                } else {
                    len = SF_sdatalen(i, j);
                    if (len < 0) len = 0;
                    if (ensure_char_buffer(&str_buf, &str_cap, (size_t)len + 1u)) goto oom;
                    rc = SF_sdata(i, j, str_buf);
                    if (rc) goto fail_rc;
                    len = (int)strlen(str_buf);
                    if (buf_u32(&b, (uint32_t)len) || buf_append(&b, str_buf, (size_t)len)) goto oom;
                }
            }
        }
    }
    rc = send_msg(MSG_DATA, "", b.data, b.len);
    free(str_buf);
    buf_free(&b);
    split_names_free(names, n_names);
    return rc;

oom:
    free(str_buf);
    buf_free(&b);
    split_names_free(names, n_names);
    return fail_msg("RStataLink2 out of memory while exporting data");

fail_rc:
    free(str_buf);
    buf_free(&b);
    split_names_free(names, n_names);
    return rc;
}

static int action_close(void) {
    clear_last();
    if (g_open) {
        nng_close(g_sock);
        g_open = 0;
    }
    return 0;
}

static void display_transport_status(const char *name, int rv) {
    SF_display((char *)name);
    SF_display(": ");
    if (rv == 0) SF_display("ok");
    else SF_display((char *)nng_strerror(rv));
    SF_display("\n");
}

static int action_version(void) {
    SF_display("RStataLink2 Stata plugin\n");
    SF_display("NNG version: ");
    SF_display((char *)nng_version());
    SF_display("\n");
    SF_display("NNG transports:\n");
    display_transport_status("  tcp", register_tcp_once());
    display_transport_status("  ipc", register_ipc_once());
    display_transport_status("  inproc", register_inproc_once());
    return 0;
}

STDLL stata_call(int argc, char *argv[]) {
    const char *action;
    if (argc < 1) return 198;
    action = argv[0];
    if (strcmp(action, "open") == 0) return action_open(argc, argv);
    if (strcmp(action, "recv") == 0) return action_recv();
    if (strcmp(action, "reply_text") == 0) return action_reply_text(argc, argv);
    if (strcmp(action, "reply_file") == 0) return action_reply_file(argc, argv);
    if (strcmp(action, "meta") == 0) return action_meta();
    if (strcmp(action, "putdf") == 0) return action_putdf();
    if (strcmp(action, "getdf") == 0) return action_getdf(argc, argv);
    if (strcmp(action, "close") == 0) return action_close();
    if (strcmp(action, "version") == 0) return action_version();
    return 198;
}
