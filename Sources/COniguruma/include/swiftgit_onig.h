/* Small helpers so Swift doesn't need the addresses of Oniguruma's globals. */
#ifndef SWIFTGIT_ONIG_H
#define SWIFTGIT_ONIG_H
#include <stddef.h>
#include "oniguruma.h"

/// Initializes Oniguruma for UTF-8 (call once; thread-safe in the caller).
int swiftgit_onig_init(void);
/// Compiles `pattern` (UTF-8) with the Oniguruma syntax, capture groups kept
/// alongside named groups. Returns ONIG_NORMAL or an error code.
int swiftgit_onig_new(OnigRegex *reg, const unsigned char *pattern, size_t length);
/// Writes the message for an error code into `buf` (at least ONIG_MAX_ERROR_MESSAGE_LEN bytes).
void swiftgit_onig_error(int code, unsigned char *buf);

#endif
