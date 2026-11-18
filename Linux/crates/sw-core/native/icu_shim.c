// Fixed names for the ICU C functions the Intl bridge calls. ICU exports
// them with its major version appended (udat_open_78), which only the headers
// resolve, so Rust cannot name them directly. Every function here forwards to
// the ICU function of the same name and nothing else.

#include <stdint.h>

#include <unicode/ucal.h>
#include <unicode/ucol.h>
#include <unicode/ucurr.h>
#include <unicode/udat.h>
#include <unicode/udatpg.h>
#include <unicode/udisplaycontext.h>
#include <unicode/ufieldpositer.h>
#include <unicode/ulistformatter.h>
#include <unicode/uloc.h>
#include <unicode/unumberformatter.h>
#include <unicode/upluralrules.h>
#include <unicode/ureldatefmt.h>
#include <unicode/uversion.h>

// Rust passes UTF-16 as uint16_t; UChar is char16_t or uint16_t depending on the compiler.
_Static_assert(sizeof(UChar) == sizeof(uint16_t), "UChar must be 16 bits");
_Static_assert(sizeof(UErrorCode) == sizeof(int32_t), "UErrorCode must be 32 bits");
_Static_assert(sizeof(UBool) == sizeof(int8_t), "UBool must be 8 bits");

typedef const uint16_t *Text;
typedef uint16_t *Buffer;
typedef int32_t *Status;

// Major, minor, patch and build number of the ICU library in use.
void sw_u_getVersion(uint8_t version[4]) { u_getVersion(version); }

int32_t sw_uloc_forLanguageTag(const char *tag, char *localeID, int32_t capacity, int32_t *parsedLength, Status status) {
    return uloc_forLanguageTag(tag, localeID, capacity, parsedLength, (UErrorCode *)status);
}

int32_t sw_ucal_getCanonicalTimeZoneID(Text id, int32_t length, Buffer result, int32_t capacity, int8_t *isSystemID, Status status) {
    return ucal_getCanonicalTimeZoneID((const UChar *)id, length, (UChar *)result, capacity, (UBool *)isSystemID, (UErrorCode *)status);
}

int32_t sw_ucal_getDefaultTimeZone(Buffer result, int32_t capacity, Status status) {
    return ucal_getDefaultTimeZone((UChar *)result, capacity, (UErrorCode *)status);
}

void *sw_udat_open(int32_t timeStyle, int32_t dateStyle, const char *locale, Text zone, int32_t zoneLength, Text pattern, int32_t patternLength, Status status) {
    return udat_open((UDateFormatStyle)timeStyle, (UDateFormatStyle)dateStyle, locale, (const UChar *)zone, zoneLength, (const UChar *)pattern, patternLength, (UErrorCode *)status);
}

void sw_udat_close(void *format) { udat_close((UDateFormat *)format); }

int32_t sw_udat_format(const void *format, double date, Buffer result, int32_t capacity, Status status) {
    return udat_format((const UDateFormat *)format, date, (UChar *)result, capacity, NULL, (UErrorCode *)status);
}

int32_t sw_udat_formatForFields(const void *format, double date, Buffer result, int32_t capacity, void *iterator, Status status) {
    return udat_formatForFields((const UDateFormat *)format, date, (UChar *)result, capacity, (UFieldPositionIterator *)iterator, (UErrorCode *)status);
}

void *sw_ufieldpositer_open(Status status) { return ufieldpositer_open((UErrorCode *)status); }
void sw_ufieldpositer_close(void *iterator) { ufieldpositer_close((UFieldPositionIterator *)iterator); }
int32_t sw_ufieldpositer_next(void *iterator, int32_t *begin, int32_t *end) { return ufieldpositer_next((UFieldPositionIterator *)iterator, begin, end); }

void *sw_udatpg_open(const char *locale, Status status) { return udatpg_open(locale, (UErrorCode *)status); }
void sw_udatpg_close(void *generator) { udatpg_close((UDateTimePatternGenerator *)generator); }
int32_t sw_udatpg_getBestPattern(void *generator, Text skeleton, int32_t length, Buffer pattern, int32_t capacity, Status status) {
    return udatpg_getBestPattern((UDateTimePatternGenerator *)generator, (const UChar *)skeleton, length, (UChar *)pattern, capacity, (UErrorCode *)status);
}

void *sw_unumf_openForSkeletonAndLocale(Text skeleton, int32_t length, const char *locale, Status status) {
    return unumf_openForSkeletonAndLocale((const UChar *)skeleton, length, locale, (UErrorCode *)status);
}
void sw_unumf_close(void *formatter) { unumf_close((UNumberFormatter *)formatter); }
void *sw_unumf_openResult(Status status) { return unumf_openResult((UErrorCode *)status); }
void sw_unumf_closeResult(void *result) { unumf_closeResult((UFormattedNumber *)result); }
void sw_unumf_formatDecimal(const void *formatter, const char *value, int32_t length, void *result, Status status) {
    unumf_formatDecimal((const UNumberFormatter *)formatter, value, length, (UFormattedNumber *)result, (UErrorCode *)status);
}
int32_t sw_unumf_resultToString(const void *result, Buffer buffer, int32_t capacity, Status status) {
    return unumf_resultToString((const UFormattedNumber *)result, (UChar *)buffer, capacity, (UErrorCode *)status);
}
// `currency` is a NUL-terminated ISO 4217 code.
int32_t sw_ucurr_getDefaultFractionDigits(Text currency, Status status) { return ucurr_getDefaultFractionDigits((const UChar *)currency, (UErrorCode *)status); }

void *sw_uplrules_openForType(const char *locale, int32_t type, Status status) { return uplrules_openForType(locale, (UPluralType)type, (UErrorCode *)status); }
void sw_uplrules_close(void *rules) { uplrules_close((UPluralRules *)rules); }
int32_t sw_uplrules_select(const void *rules, double number, Buffer keyword, int32_t capacity, Status status) {
    return uplrules_select((const UPluralRules *)rules, number, (UChar *)keyword, capacity, (UErrorCode *)status);
}

void *sw_ureldatefmt_open(const char *locale, int32_t width, Status status) {
    return ureldatefmt_open(locale, NULL, (UDateRelativeDateTimeFormatterStyle)width, UDISPCTX_CAPITALIZATION_NONE, (UErrorCode *)status);
}
void sw_ureldatefmt_close(void *formatter) { ureldatefmt_close((URelativeDateTimeFormatter *)formatter); }
int32_t sw_ureldatefmt_format(const void *formatter, double offset, int32_t unit, Buffer result, int32_t capacity, Status status) {
    return ureldatefmt_format((const URelativeDateTimeFormatter *)formatter, offset, (URelativeDateTimeUnit)unit, (UChar *)result, capacity, (UErrorCode *)status);
}
int32_t sw_ureldatefmt_formatNumeric(const void *formatter, double offset, int32_t unit, Buffer result, int32_t capacity, Status status) {
    return ureldatefmt_formatNumeric((const URelativeDateTimeFormatter *)formatter, offset, (URelativeDateTimeUnit)unit, (UChar *)result, capacity, (UErrorCode *)status);
}

void *sw_ucol_open(const char *locale, Status status) { return ucol_open(locale, (UErrorCode *)status); }
void sw_ucol_close(void *collator) { ucol_close((UCollator *)collator); }
int32_t sw_ucol_strcoll(const void *collator, Text source, int32_t sourceLength, Text target, int32_t targetLength) {
    return (int32_t)ucol_strcoll((const UCollator *)collator, (const UChar *)source, sourceLength, (const UChar *)target, targetLength);
}

void *sw_ulistfmt_openForType(const char *locale, int32_t type, int32_t width, Status status) {
    return ulistfmt_openForType(locale, (UListFormatterType)type, (UListFormatterWidth)width, (UErrorCode *)status);
}
void sw_ulistfmt_close(void *formatter) { ulistfmt_close((UListFormatter *)formatter); }
int32_t sw_ulistfmt_format(const void *formatter, const Text *strings, const int32_t *lengths, int32_t count, Buffer result, int32_t capacity, Status status) {
    return ulistfmt_format((const UListFormatter *)formatter, (const UChar *const *)strings, lengths, count, (UChar *)result, capacity, (UErrorCode *)status);
}
