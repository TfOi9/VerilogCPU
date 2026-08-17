/* Return the sum of all integers in the inclusive range [0, 100]. */
int main(void)
{
    int sum = 0;
    int value;
    static volatile int zero_area[2];

    for (value = 0; value <= 100; ++value) {
        sum += value;
    }
    zero_area[0] = sum;
    return sum + zero_area[1];
}
