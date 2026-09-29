#ifndef XAUTH_H
#define XAUTH_H

#include <stddef.h>

typedef struct {
    void (*show_code)(const char *url, const char *code);
    void (*log)(const char *msg);
} xauth_hooks;

/* Refreshes or runs the Microsoft device-code login and writes tokens.txt.
 * Returns 1 on success, 0 with a reason in err. */
int xauth_sign_in(const char *token_path, const xauth_hooks *hooks, char *err, size_t errsz);

#endif
