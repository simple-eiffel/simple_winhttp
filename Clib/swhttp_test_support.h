/*
 * swhttp_test_support.h - a sleep and a clock for simple_winhttp's SCOOP tests.
 * Tests only; nothing in src/ includes it.
 *
 * Copyright (c) 2026 Larry Rix - MIT License
 */

#ifndef SWHTTP_TEST_SUPPORT_H
#define SWHTTP_TEST_SUPPORT_H

#if defined(_WIN32) || defined(EIF_WINDOWS)

#include <windows.h>

static void swt_sleep_ms(int a_ms) { Sleep((DWORD) a_ms); }

static long long swt_now_ms(void)
{
    LARGE_INTEGER c, f;
    QueryPerformanceCounter(&c);
    QueryPerformanceFrequency(&f);
    return (c.QuadPart * 1000) / f.QuadPart;
}

#else

#include <errno.h>
#include <time.h>

static void swt_sleep_ms(int a_ms)
{
    struct timespec l_left;
    l_left.tv_sec = a_ms / 1000;
    l_left.tv_nsec = (long) (a_ms % 1000) * 1000000L;
    while (nanosleep(&l_left, &l_left) != 0 && errno == EINTR) { }
}

static long long swt_now_ms(void)
{
    struct timespec l_now;
    clock_gettime(CLOCK_MONOTONIC, &l_now);
    return (long long) l_now.tv_sec * 1000 + l_now.tv_nsec / 1000000;
}

#endif

#endif /* SWHTTP_TEST_SUPPORT_H */
