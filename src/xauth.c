/* Microsoft account sign-in for the stand-in runtime.
 *
 * Uses this game's Microsoft app id with the device-code flow, then trades the
 * MSA ticket for Xbox Live tokens. Tokens go to tokens.txt and are never logged.
 * Everything runs on Wine's WinHTTP and BCrypt, so the host needs nothing
 * installed. */
#include <windows.h>
#include <bcrypt.h>
#include <winhttp.h>
#include <shellapi.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "xauth.h"

#define CLIENT "00000000497C1B94"
#define SCOPE "service::user.auth.xboxlive.com::MBI_SSL"

static const xauth_hooks *g_hooks;

static void say(const char *fmt, ...)
{
    char buf[400];
    va_list ap;
    if (!g_hooks || !g_hooks->log) return;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    g_hooks->log(buf);
}

/* strings */

typedef struct {
    char *p;
    size_t n, cap;
} sbuf;

static int sb_add(sbuf *b, const void *data, size_t len)
{
    if (b->n + len + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 1024;
        char *p;
        while (b->n + len + 1 > cap) cap *= 2;
        p = realloc(b->p, cap);
        if (!p) return 0;
        b->p = p;
        b->cap = cap;
    }
    memcpy(b->p + b->n, data, len);
    b->n += len;
    b->p[b->n] = 0;
    return 1;
}

static int sb_str(sbuf *b, const char *s) { return sb_add(b, s, strlen(s)); }

static int sb_printf(sbuf *b, const char *fmt, ...)
{
    va_list ap;
    int len;
    char *tmp;
    va_start(ap, fmt);
    len = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (len < 0) return 0;
    tmp = malloc((size_t)len + 1);
    if (!tmp) return 0;
    va_start(ap, fmt);
    vsnprintf(tmp, (size_t)len + 1, fmt, ap);
    va_end(ap);
    len = sb_add(b, tmp, strlen(tmp));
    free(tmp);
    return len;
}

static void sb_form(sbuf *b, const char *key, const char *val)
{
    static const char hex[] = "0123456789ABCDEF";
    if (b->n) sb_str(b, "&");
    sb_str(b, key);
    sb_str(b, "=");
    for (; *val; val++) {
        unsigned char c = (unsigned char)*val;
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == '~') {
            sb_add(b, &c, 1);
        } else {
            char e[3] = { '%', hex[c >> 4], hex[c & 15] };
            sb_add(b, e, 3);
        }
    }
}

/* base64 */

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const char B64URL[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static void b64_encode(sbuf *out, const unsigned char *in, size_t len, int url)
{
    const char *tab = url ? B64URL : B64;
    size_t i;
    for (i = 0; i < len; i += 3) {
        unsigned v = (unsigned)in[i] << 16;
        char q[4];
        int n = 2;
        if (i + 1 < len) { v |= (unsigned)in[i + 1] << 8; n++; }
        if (i + 2 < len) { v |= in[i + 2]; n++; }
        q[0] = tab[(v >> 18) & 63];
        q[1] = tab[(v >> 12) & 63];
        q[2] = n > 2 ? tab[(v >> 6) & 63] : '=';
        q[3] = n > 3 ? tab[v & 63] : '=';
        sb_add(out, q, url ? (size_t)n : 4);
    }
}

static size_t b64url_decode(const char *in, size_t len, unsigned char *out, size_t outsz)
{
    unsigned v = 0;
    int bits = 0;
    size_t i, n = 0;
    for (i = 0; i < len; i++) {
        char c = in[i];
        int d;
        if (c >= 'A' && c <= 'Z') d = c - 'A';
        else if (c >= 'a' && c <= 'z') d = c - 'a' + 26;
        else if (c >= '0' && c <= '9') d = c - '0' + 52;
        else if (c == '-' || c == '+') d = 62;
        else if (c == '_' || c == '/') d = 63;
        else continue;
        v = (v << 6) | (unsigned)d;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (n < outsz) out[n++] = (unsigned char)(v >> bits);
        }
    }
    return n;
}

/* JSON: flat key lookup. Every key read here is unique within its response. */

static const char *json_skip_string(const char *p)
{
    for (p++; *p && *p != '"'; p++)
        if (*p == '\\' && p[1]) p++;
    return *p ? p + 1 : p;
}

static void put_utf8(sbuf *b, unsigned cp)
{
    unsigned char o[4];
    size_t n;
    if (cp < 0x80) { o[0] = (unsigned char)cp; n = 1; }
    else if (cp < 0x800) { o[0] = 0xC0 | (cp >> 6); o[1] = 0x80 | (cp & 63); n = 2; }
    else if (cp < 0x10000) { o[0] = 0xE0 | (cp >> 12); o[1] = 0x80 | ((cp >> 6) & 63); o[2] = 0x80 | (cp & 63); n = 3; }
    else { o[0] = 0xF0 | (cp >> 18); o[1] = 0x80 | ((cp >> 12) & 63); o[2] = 0x80 | ((cp >> 6) & 63); o[3] = 0x80 | (cp & 63); n = 4; }
    sb_add(b, o, n);
}

static unsigned hex4(const char *p)
{
    unsigned v = 0;
    int i;
    for (i = 0; i < 4; i++) {
        char c = p[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
        else return 0xFFFFFFFFu;
    }
    return v;
}

/* Returns a malloc'd copy of the string or scalar value for key, or NULL. */
static char *json_get(const char *json, const char *key)
{
    size_t klen = strlen(key);
    const char *p = json;
    if (!json) return NULL;
    while (*p) {
        const char *s, *e, *v;
        if (*p != '"') { p++; continue; }
        s = p + 1;
        e = json_skip_string(p);
        p = e;
        if ((size_t)(e - 1 - s) != klen || memcmp(s, key, klen)) continue;
        v = e;
        while (*v == ' ' || *v == '\t' || *v == '\r' || *v == '\n') v++;
        if (*v != ':') continue;
        v++;
        while (*v == ' ' || *v == '\t' || *v == '\r' || *v == '\n') v++;
        if (*v == '"') {
            sbuf out = { 0 };
            for (v++; *v && *v != '"'; v++) {
                if (*v != '\\') { sb_add(&out, v, 1); continue; }
                v++;
                switch (*v) {
                case 'b': sb_str(&out, "\b"); break;
                case 'f': sb_str(&out, "\f"); break;
                case 'n': sb_str(&out, "\n"); break;
                case 'r': sb_str(&out, "\r"); break;
                case 't': sb_str(&out, "\t"); break;
                case 'u': {
                    unsigned cp = hex4(v + 1);
                    if (cp == 0xFFFFFFFFu) return free(out.p), NULL;
                    v += 4;
                    if (cp >= 0xD800 && cp < 0xDC00 && v[1] == '\\' && v[2] == 'u') {
                        unsigned lo = hex4(v + 3);
                        if (lo >= 0xDC00 && lo < 0xE000) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            v += 6;
                        }
                    }
                    put_utf8(&out, cp);
                    break;
                }
                case 0: return free(out.p), NULL;
                default: sb_add(&out, v, 1); break;
                }
            }
            if (!out.p) sb_str(&out, "");
            return out.p;
        }
        if (*v == '{' || *v == '[') return NULL;
        e = v;
        while (*e && *e != ',' && *e != '}' && *e != ']' && *e != ' ' && *e != '\r' && *e != '\n') e++;
        {
            char *out = malloc((size_t)(e - v) + 1);
            if (!out) return NULL;
            memcpy(out, v, (size_t)(e - v));
            out[e - v] = 0;
            return out;
        }
    }
    return NULL;
}

static void copy_str(char *dst, size_t dstsz, const char *src)
{
    snprintf(dst, dstsz, "%s", src ? src : "");
}

/* Short reason from an error response, for logs and login-error text. */
static void json_reason(const char *json, int status, const char *const *keys, char *out, size_t outsz)
{
    size_t i;
    for (i = 0; keys[i]; i++) {
        char *v = json_get(json, keys[i]);
        if (v && v[0]) {
            copy_str(out, outsz, v);
            free(v);
            return;
        }
        free(v);
    }
    snprintf(out, outsz, "HTTP %d", status);
}

static const char *const XBL_ERR[] = { "XErr", "error", NULL };
static const char *const MSA_ERR[] = { "error_description", "error", NULL };

/* crypto */

static BCRYPT_KEY_HANDLE g_proof_key;
static unsigned char g_proof_x[32], g_proof_y[32];

static int random_bytes(void *buf, ULONG len)
{
    return BCryptGenRandom(NULL, buf, len, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
}

static int sha256(const void *data, size_t len, unsigned char out[32])
{
    BCRYPT_ALG_HANDLE alg;
    NTSTATUS st;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0)) return 0;
    st = BCryptHash(alg, NULL, 0, (PUCHAR)data, (ULONG)len, out, 32);
    BCryptCloseAlgorithmProvider(alg, 0);
    return st == 0;
}

static int proof_key(void)
{
    BCRYPT_ALG_HANDLE alg;
    unsigned char blob[sizeof(BCRYPT_ECCKEY_BLOB) + 64];
    ULONG n = 0;
    BCRYPT_KEY_HANDLE key = NULL;
    if (g_proof_key) return 1;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_ECDSA_P256_ALGORITHM, NULL, 0)) return 0;
    if (BCryptGenerateKeyPair(alg, &key, 256, 0) || BCryptFinalizeKeyPair(key, 0) ||
        BCryptExportKey(key, NULL, BCRYPT_ECCPUBLIC_BLOB, blob, sizeof blob, &n, 0) ||
        n != sizeof blob) {
        if (key) BCryptDestroyKey(key);
        BCryptCloseAlgorithmProvider(alg, 0);
        return 0;
    }
    /* the algorithm handle has to outlive the key */
    memcpy(g_proof_x, blob + sizeof(BCRYPT_ECCKEY_BLOB), 32);
    memcpy(g_proof_y, blob + sizeof(BCRYPT_ECCKEY_BLOB) + 32, 32);
    g_proof_key = key;
    return 1;
}

static void put_be(unsigned char *p, unsigned long long v, int len)
{
    int i;
    for (i = len - 1; i >= 0; i--, v >>= 8) p[i] = (unsigned char)v;
}

/* Xbox request signing: ES256 over version, filetime, method, path, auth header and body. */
static int xbl_signature(const wchar_t *path, const char *body, sbuf *out)
{
    FILETIME ft;
    unsigned long long stamp;
    unsigned char head[12], digest[32], sig[64];
    char pathbuf[256] = "";
    ULONG n = 0;
    sbuf msg = { 0 };
    int ok;
    GetSystemTimeAsFileTime(&ft);
    stamp = ((unsigned long long)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    put_be(head, 1, 4);
    put_be(head + 4, stamp, 8);
    WideCharToMultiByte(CP_UTF8, 0, path, -1, pathbuf, sizeof pathbuf, NULL, NULL);
    sb_add(&msg, head, 4);
    sb_add(&msg, "", 1);
    sb_add(&msg, head + 4, 8);
    sb_add(&msg, "", 1);
    sb_add(&msg, "POST", 5);
    sb_add(&msg, pathbuf, strlen(pathbuf) + 1);
    sb_add(&msg, "", 1);
    sb_add(&msg, body, strlen(body) + 1);
    ok = msg.p && sha256(msg.p, msg.n, digest) &&
         !BCryptSignHash(g_proof_key, NULL, digest, 32, sig, sizeof sig, &n, 0) && n == 64;
    free(msg.p);
    if (!ok) return 0;
    {
        unsigned char raw[12 + 64];
        memcpy(raw, head, 12);
        memcpy(raw + 12, sig, 64);
        b64_encode(out, raw, sizeof raw, 0);
    }
    return 1;
}

/* HTTP */

static wchar_t *widen(const char *s)
{
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    wchar_t *w = n > 0 ? malloc(sizeof(wchar_t) * (size_t)n) : NULL;
    if (w) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

/* POSTs body and returns the response text (JSON or not). *status is 0 when
 * the request never got an answer. */
static char *http_post(const char *url, const char *type, const char *body, int signed_req, int *status)
{
    URL_COMPONENTS uc;
    wchar_t host[128], path[512];
    wchar_t *wurl = widen(url), *wheaders = NULL;
    HINTERNET ses = NULL, con = NULL, req = NULL;
    sbuf headers = { 0 }, resp = { 0 };
    DWORD code = 0, len = sizeof code;
    *status = 0;
    if (!body || !wurl) {
        free(wurl);
        return NULL;
    }
    memset(&uc, 0, sizeof uc);
    uc.dwStructSize = sizeof uc;
    uc.lpszHostName = host;
    uc.dwHostNameLength = sizeof host / sizeof host[0];
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = sizeof path / sizeof path[0];
    if (!WinHttpCrackUrl(wurl, 0, 0, &uc)) goto done;

    sb_printf(&headers, "Content-Type: %s\r\nAccept: application/json\r\n", type);
    if (signed_req) {
        sbuf sig = { 0 };
        if (!xbl_signature(path, body, &sig)) {
            free(sig.p);
            goto done;
        }
        sb_printf(&headers, "x-xbl-contract-version: 1\r\nSignature: %s\r\n", sig.p);
        free(sig.p);
    }
    wheaders = widen(headers.p);
    if (!wheaders) goto done;

    ses = WinHttpOpen(L"Dungeons2-compat", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, NULL, NULL, 0);
    if (!ses) ses = WinHttpOpen(L"Dungeons2-compat", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    if (!ses) goto done;
    WinHttpSetTimeouts(ses, 30000, 30000, 30000, 30000);
    con = WinHttpConnect(ses, host, uc.nPort, 0);
    if (!con) goto done;
    req = WinHttpOpenRequest(con, L"POST", path, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                             uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0);
    if (!req) goto done;
    if (!WinHttpSendRequest(req, wheaders, (DWORD)-1L, (void *)body, (DWORD)strlen(body), (DWORD)strlen(body), 0) ||
        !WinHttpReceiveResponse(req, NULL))
        goto done;
    if (!WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                             &code, &len, WINHTTP_NO_HEADER_INDEX))
        goto done;
    for (;;) {
        char chunk[8192];
        DWORD got = 0;
        if (!WinHttpReadData(req, chunk, sizeof chunk, &got) || !got) break;
        sb_add(&resp, chunk, got);
    }
    if (!resp.p) sb_str(&resp, "");
    *status = (int)code;

done:
    if (!*status) say("xauth POST %s failed %lu", url, (unsigned long)GetLastError());
    if (req) WinHttpCloseHandle(req);
    if (con) WinHttpCloseHandle(con);
    if (ses) WinHttpCloseHandle(ses);
    free(wurl);
    free(wheaders);
    free(headers.p);
    if (!*status) {
        free(resp.p);
        return NULL;
    }
    return resp.p;
}

static char *post_form(const char *url, const char *form, int *status)
{
    return http_post(url, "application/x-www-form-urlencoded", form, 0, status);
}

static char *post_json(const char *url, const char *json, int signed_req, int *status)
{
    return http_post(url, "application/json", json, signed_req, status);
}

/* Xbox Live */

static long long jwt_exp(const char *token)
{
    const char *semi, *dot1, *dot2;
    unsigned char payload[4096];
    size_t n;
    char *exp;
    long long v;
    if (!token) return 0;
    semi = strrchr(token, ';');
    if (semi) token = semi + 1;
    dot1 = strchr(token, '.');
    if (!dot1) return 0;
    dot2 = strchr(dot1 + 1, '.');
    if (!dot2) return 0;
    n = b64url_decode(dot1 + 1, (size_t)(dot2 - dot1 - 1), payload, sizeof payload - 1);
    payload[n] = 0;
    exp = json_get((const char *)payload, "exp");
    v = exp ? atoll(exp) : 0;
    free(exp);
    return v;
}

static char *xbox_user(const char *access, char *err, size_t errsz)
{
    sbuf body = { 0 };
    const char *prefix = "";
    char *resp, *tok;
    int status;
    if (strncmp(access, "t=", 2) && strncmp(access, "d=", 2))
        prefix = strncmp(access, "eyJ", 3) ? "t=" : "d=";
    sb_printf(&body, "{\"Properties\":{\"AuthMethod\":\"RPS\",\"SiteName\":\"user.auth.xboxlive.com\","
                     "\"RpsTicket\":\"%s%s\"},\"RelyingParty\":\"http://auth.xboxlive.com\",\"TokenType\":\"JWT\"}",
              prefix, access);
    resp = post_json("https://user.auth.xboxlive.com/user/authenticate", body.p, 0, &status);
    free(body.p);
    tok = json_get(resp, "Token");
    if (!tok) {
        char why[200];
        json_reason(resp, status, XBL_ERR, why, sizeof why);
        snprintf(err, errsz, "Xbox user auth failed: %s", why);
    }
    free(resp);
    return tok;
}

static char *device_token(char *err, size_t errsz)
{
    sbuf body = { 0 }, x = { 0 }, y = { 0 };
    unsigned char id[16];
    char *resp, *tok;
    int status;
    if (!proof_key() || !random_bytes(id, sizeof id)) {
        copy_str(err, errsz, "no ECDSA key");
        return NULL;
    }
    id[6] = (id[6] & 0x0F) | 0x40;
    id[8] = (id[8] & 0x3F) | 0x80;
    b64_encode(&x, g_proof_x, 32, 1);
    b64_encode(&y, g_proof_y, 32, 1);
    sb_printf(&body,
              "{\"Properties\":{\"AuthMethod\":\"ProofOfPossession\","
              "\"Id\":\"{%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x}\","
              "\"DeviceType\":\"Win32\",\"Version\":\"10.0.19045\","
              "\"ProofKey\":{\"kty\":\"EC\",\"x\":\"%s\",\"y\":\"%s\",\"crv\":\"P-256\",\"alg\":\"ES256\",\"use\":\"sig\"}},"
              "\"RelyingParty\":\"http://auth.xboxlive.com\",\"TokenType\":\"JWT\"}",
              id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
              id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15], x.p, y.p);
    free(x.p);
    free(y.p);
    resp = post_json("https://device.auth.xboxlive.com/device/authenticate", body.p, 1, &status);
    free(body.p);
    tok = json_get(resp, "Token");
    if (!tok) json_reason(resp, status, XBL_ERR, err, errsz);
    free(resp);
    return tok;
}

/* Returns the whole XSTS response, or NULL with err set. */
static char *xsts(const char *user_token, const char *relying, const char *device, char *err, size_t errsz)
{
    sbuf body = { 0 };
    char *resp, *tok;
    int status;
    sb_str(&body, "{\"Properties\":{\"SandboxId\":\"RETAIL\",\"UserTokens\":[\"");
    sb_str(&body, user_token);
    sb_str(&body, "\"]");
    if (device) sb_printf(&body, ",\"DeviceToken\":\"%s\"", device);
    sb_printf(&body, "},\"RelyingParty\":\"%s\",\"TokenType\":\"JWT\"}", relying);
    resp = post_json("https://xsts.auth.xboxlive.com/xsts/authorize", body.p, device != NULL, &status);
    free(body.p);
    tok = json_get(resp, "Token");
    if (!tok) {
        json_reason(resp, status, XBL_ERR, err, errsz);
        free(resp);
        return NULL;
    }
    free(tok);
    return resp;
}

/* "XBL3.0 x=<uhs>;<token>" from an XSTS response. */
static char *auth_header(const char *doc)
{
    char *uhs = json_get(doc, "uhs"), *tok = json_get(doc, "Token");
    sbuf out = { 0 };
    if (uhs && tok) sb_printf(&out, "XBL3.0 x=%s;%s", uhs, tok);
    free(uhs);
    free(tok);
    return out.p;
}

/* tokens.txt */

typedef char *(CDECL *unix_name_fn)(const WCHAR *);

/* Tokens are the user's credentials; keep them out of other accounts' reach.
 * Wine doesn't wait on native children, so the chmod lands shortly after. */
static void native_chmod(const char *mode, const char *path)
{
    static unix_name_fn unix_name;
    char cmd[800];
    char *upath;
    WCHAR *wpath;
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    if (!unix_name) unix_name = (unix_name_fn)(void *)GetProcAddress(GetModuleHandleA("kernel32.dll"), "wine_get_unix_file_name");
    if (!unix_name || GetFileAttributesA("Z:\\bin\\chmod") == INVALID_FILE_ATTRIBUTES) return;
    wpath = widen(path);
    upath = wpath ? unix_name(wpath) : NULL;
    free(wpath);
    if (!upath) return;
    if (!strchr(upath, '"')) {
        snprintf(cmd, sizeof cmd, "\"Z:\\bin\\chmod\" %s \"%s\"", mode, upath);
        memset(&si, 0, sizeof si);
        si.cb = sizeof si;
        if (CreateProcessA(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }
    }
    HeapFree(GetProcessHeap(), 0, upath);
}

static void lock_token_dir(const char *token_path)
{
    char dir[600];
    char *slash;
    snprintf(dir, sizeof dir, "%s", token_path);
    slash = strrchr(dir, '\\');
    if (!slash) return;
    *slash = 0;
    native_chmod("700", dir);
}

static char *read_refresh(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[16000];
    char *out = NULL;
    if (!f) return NULL;
    while (!out && fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        if (!strncmp(line, "refresh=", 8) && line[8]) out = _strdup(line + 8);
    }
    fclose(f);
    return out;
}

static int write_tokens(const char *path, const char *text)
{
    char tmp[600];
    FILE *f;
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    f = fopen(tmp, "wb");
    if (!f) return 0;
    if (fputs(text, f) < 0) {
        fclose(f);
        DeleteFileA(tmp);
        return 0;
    }
    if (fclose(f) || !MoveFileExA(tmp, path, MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileA(tmp);
        return 0;
    }
    native_chmod("600", path);
    return 1;
}

/* sign-in */

static int finish(const char *token_path, const char *access, const char *refresh, char *err, size_t errsz)
{
    char *user, *xbox = NULL, *mc = NULL, *device = NULL, *pf = NULL;
    char *xbox_h = NULL, *mc_h = NULL, *pf_h = NULL, *xuid = NULL, *uhs = NULL, *gtg = NULL;
    char why[200] = "", mc_err[200] = "", pf_err[200] = "";
    long long exp, e;
    sbuf out = { 0 };
    int ok = 0;

    user = xbox_user(access, err, errsz);
    if (!user) return 0;
    xbox = xsts(user, "http://xboxlive.com", NULL, why, sizeof why);
    if (!xbox) {
        snprintf(err, errsz, "Xbox token failed: %s", why);
        goto done;
    }
    mc = xsts(user, "rp://api.minecraftservices.com/", NULL, mc_err, sizeof mc_err);
    device = device_token(pf_err, sizeof pf_err);
    if (device) pf = xsts(user, "http://playfab.xboxlive.com/", device, pf_err, sizeof pf_err);
    say("xauth minecraft %s, playfab %s", mc ? "ok" : mc_err, pf ? "ok" : pf_err);

    xbox_h = auth_header(xbox);
    mc_h = mc ? auth_header(mc) : NULL;
    pf_h = pf ? auth_header(pf) : NULL;
    xuid = json_get(xbox, "xid");
    uhs = json_get(xbox, "uhs");
    gtg = json_get(xbox, "gtg");
    if (!xbox_h) {
        copy_str(err, errsz, "Xbox token had no claims");
        goto done;
    }

    exp = jwt_exp(xbox_h);
    e = mc_h ? jwt_exp(mc_h) : 0;
    if (e && (!exp || e < exp)) exp = e;
    e = pf_h ? jwt_exp(pf_h) : 0;
    if (e && (!exp || e < exp)) exp = e;
    if (!exp) exp = (long long)time(NULL) + 4 * 3600;

    sb_printf(&out, "exp=%lld\n", exp);
    sb_printf(&out, "xuid=%s\n", xuid ? xuid : "0");
    sb_printf(&out, "uhs=%s\n", uhs ? uhs : "");
    sb_printf(&out, "gamertag=%s\n", gtg ? gtg : "Player");
    sb_printf(&out, "xbox=%s\n", xbox_h);
    sb_printf(&out, "mc=%s\n", mc_h ? mc_h : "");
    sb_printf(&out, "playfab=%s\n", pf_h ? pf_h : "");
    sb_printf(&out, "msa=%s\n", access);
    sb_printf(&out, "refresh=%s\n", refresh ? refresh : "");
    sb_printf(&out, "mc_error=%s\n", mc ? "" : mc_err);
    sb_printf(&out, "playfab_error=%s\n", pf ? "" : pf_err);
    ok = out.p && write_tokens(token_path, out.p);
    if (!ok) snprintf(err, errsz, "could not write %s", token_path);

done:
    if (out.p) SecureZeroMemory(out.p, out.n);
    free(out.p);
    free(user); free(xbox); free(mc); free(device); free(pf);
    free(xbox_h); free(mc_h); free(pf_h); free(xuid); free(uhs); free(gtg);
    return ok;
}

static int finish_msa(const char *token_path, const char *resp, const char *old_refresh, char *err, size_t errsz)
{
    char *access = json_get(resp, "access_token"), *refresh = json_get(resp, "refresh_token");
    int ok = access && finish(token_path, access, refresh ? refresh : old_refresh, err, errsz);
    free(access);
    free(refresh);
    return ok;
}

static void open_browser(const char *url)
{
    const char *opener = NULL;
    char cmd[600];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    /* Wine execs non-PE images natively through CreateProcess */
    if (GetFileAttributesA("Z:\\System\\Library\\CoreServices\\SystemVersion.plist") != INVALID_FILE_ATTRIBUTES)
        opener = "Z:\\usr\\bin\\open";
    else if (GetFileAttributesA("Z:\\usr\\bin\\xdg-open") != INVALID_FILE_ATTRIBUTES)
        opener = "Z:\\usr\\bin\\xdg-open";
    if (opener) {
        snprintf(cmd, sizeof cmd, "\"%s\" \"%s\"", opener, url);
        memset(&si, 0, sizeof si);
        si.cb = sizeof si;
        if (CreateProcessA(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            return;
        }
    }
    ShellExecuteA(NULL, "open", url, NULL, NULL, SW_SHOWNORMAL);
}

static int device_login(const char *token_path, char *err, size_t errsz)
{
    sbuf form = { 0 };
    char *resp, *device_code, *user_code, *uri, *v;
    int status, interval, expires, ok = 0;
    DWORD deadline;

    sb_form(&form, "client_id", CLIENT);
    sb_form(&form, "scope", SCOPE);
    sb_form(&form, "response_type", "device_code");
    resp = post_form("https://login.live.com/oauth20_connect.srf", form.p, &status);
    free(form.p);
    device_code = json_get(resp, "device_code");
    user_code = json_get(resp, "user_code");
    uri = json_get(resp, "verification_uri");
    if (!device_code || !user_code) {
        char why[200];
        json_reason(resp, status, MSA_ERR, why, sizeof why);
        snprintf(err, errsz, "Could not start Microsoft login: %s", why);
        goto done;
    }
    if (uri && (strncmp(uri, "https://", 8) || strchr(uri, '"'))) {
        free(uri);
        uri = NULL;
    }
    if (!uri) uri = _strdup("https://www.microsoft.com/link");
    v = json_get(resp, "interval");
    interval = v ? atoi(v) : 5;
    free(v);
    v = json_get(resp, "expires_in");
    expires = v ? atoi(v) : 900;
    free(v);
    deadline = GetTickCount() + (DWORD)(expires > 35 ? expires - 5 : 30) * 1000;

    if (g_hooks && g_hooks->show_code) g_hooks->show_code(uri, user_code);
    open_browser(uri);

    for (;;) {
        char *poll, *error;
        if (interval < 5) interval = 5;
        Sleep((DWORD)interval * 1000);
        if ((LONG)(GetTickCount() - deadline) >= 0) {
            copy_str(err, errsz, "Microsoft login timed out");
            break;
        }
        form.p = NULL;
        form.n = form.cap = 0;
        sb_form(&form, "client_id", CLIENT);
        sb_form(&form, "grant_type", "urn:ietf:params:oauth:grant-type:device_code");
        sb_form(&form, "device_code", device_code);
        poll = post_form("https://login.live.com/oauth20_token.srf", form.p, &status);
        free(form.p);
        if (!poll) continue;
        v = json_get(poll, "access_token");
        if (v) {
            free(v);
            ok = finish_msa(token_path, poll, NULL, err, errsz);
            free(poll);
            break;
        }
        error = json_get(poll, "error");
        if (error && !strcmp(error, "slow_down")) interval += 5;
        if (!error || (strcmp(error, "slow_down") && strcmp(error, "authorization_pending"))) {
            char why[200];
            json_reason(poll, status, MSA_ERR, why, sizeof why);
            snprintf(err, errsz, "Microsoft login failed: %s", why);
            free(error);
            free(poll);
            break;
        }
        free(error);
        free(poll);
    }

done:
    free(resp);
    free(device_code);
    free(user_code);
    free(uri);
    return ok;
}

/* 1 ok, 0 refresh token rejected, -1 failed for a reason a new login won't fix */
static int refresh_login(const char *token_path, const char *refresh, char *err, size_t errsz)
{
    sbuf form = { 0 };
    char *resp, *access;
    int status, ok = 0;
    sb_form(&form, "client_id", CLIENT);
    sb_form(&form, "grant_type", "refresh_token");
    sb_form(&form, "refresh_token", refresh);
    sb_form(&form, "scope", SCOPE);
    if (!form.p) return -1;
    resp = post_form("https://login.live.com/oauth20_token.srf", form.p, &status);
    SecureZeroMemory(form.p, form.n);
    free(form.p);
    access = json_get(resp, "access_token");
    if (access) ok = finish_msa(token_path, resp, refresh, err, errsz) ? 1 : -1;
    else if (!status) {
        copy_str(err, errsz, "login.live.com unreachable");
        ok = -1;
    } else say("xauth refresh rejected (HTTP %d)", status);
    free(access);
    if (resp) SecureZeroMemory(resp, strlen(resp));
    free(resp);
    return ok;
}

int xauth_sign_in(const char *token_path, const xauth_hooks *hooks, char *err, size_t errsz)
{
    char *refresh;
    int ok = 0;
    g_hooks = hooks;
    err[0] = 0;
    lock_token_dir(token_path);
    refresh = read_refresh(token_path);
    if (refresh) {
        ok = refresh_login(token_path, refresh, err, errsz);
        SecureZeroMemory(refresh, strlen(refresh));
        free(refresh);
        if (ok) return ok > 0;
    }
    return device_login(token_path, err, errsz);
}
