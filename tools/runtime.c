/* Minimal freestanding runtime used by bare-metal test programs. */

void *memset(void *dst, int value, unsigned int count)
{
    unsigned char *out = (unsigned char *)dst;
    while (count != 0u) {
        *out++ = (unsigned char)value;
        --count;
    }
    return dst;
}

void *memcpy(void *dst, const void *src, unsigned int count)
{
    unsigned char *out = (unsigned char *)dst;
    const unsigned char *in = (const unsigned char *)src;
    while (count != 0u) {
        *out++ = *in++;
        --count;
    }
    return dst;
}

void *memmove(void *dst, const void *src, unsigned int count)
{
    unsigned char *out = (unsigned char *)dst;
    const unsigned char *in = (const unsigned char *)src;

    if (out < in) {
        while (count != 0u) {
            *out++ = *in++;
            --count;
        }
    } else {
        out += count;
        in += count;
        while (count != 0u) {
            *--out = *--in;
            --count;
        }
    }
    return dst;
}
