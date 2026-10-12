#include "swiftgit_onig.h"

int swiftgit_onig_init(void) {
    OnigEncoding encodings[1] = { ONIG_ENCODING_UTF8 };
    return onig_initialize(encodings, 1);
}

int swiftgit_onig_new(OnigRegex *reg, const unsigned char *pattern, size_t length) {
    OnigErrorInfo info;
    return onig_new(reg, pattern, pattern + length, ONIG_OPTION_CAPTURE_GROUP,
                    ONIG_ENCODING_UTF8, ONIG_SYNTAX_ONIGURUMA, &info);
}

void swiftgit_onig_error(int code, unsigned char *buf) {
    onig_error_code_to_str(buf, code);
}
