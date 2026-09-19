package com.cangshu.common;

import java.security.SecureRandom;
import java.util.UUID;

/**
 * UUIDv7 生成器（RFC 9562）：48 位 Unix 毫秒时间戳 ＋ 版本 7 ＋ 随机位。
 *
 * <p>《06-M1-数据契约》总则约定 ID 为 UUIDv7；JDK 21 未内置，按 RFC 位布局自实现，
 * 不引入额外依赖。时间戳取自 {@link System#currentTimeMillis()}，同毫秒内随机排序。
 */
public final class UuidV7 {

    private static final SecureRandom RANDOM = new SecureRandom();

    private UuidV7() {
    }

    /** 生成一个 UUIDv7。 */
    public static UUID generate() {
        long timestampMillis = System.currentTimeMillis();
        byte[] random = new byte[10];
        RANDOM.nextBytes(random);

        // msb：48 位 unix_ts_ms ｜ 4 位版本 0111 ｜ 12 位 rand_a
        long randA = ((random[0] & 0x0FL) << 8) | (random[1] & 0xFFL);
        long msb = ((timestampMillis & 0xFFFFFFFFFFFFL) << 16)
                | 0x7000L
                | randA;

        // lsb：2 位变体 10 ｜ 62 位 rand_b
        long lsb = 0;
        for (int index = 2; index < 10; index++) {
            lsb = (lsb << 8) | (random[index] & 0xFFL);
        }
        lsb = (lsb & 0x3FFFFFFFFFFFFFFFL) | 0x8000000000000000L;

        return new UUID(msb, lsb);
    }

    /** 从 UUIDv7 提取 48 位 Unix 毫秒时间戳（校验/测试用）。 */
    public static long timestampMillis(UUID uuid) {
        return uuid.getMostSignificantBits() >>> 16;
    }
}
