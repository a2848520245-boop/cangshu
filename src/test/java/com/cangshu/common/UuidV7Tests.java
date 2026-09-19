package com.cangshu.common;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.UUID;
import org.junit.jupiter.api.Test;

/** UUIDv7 位布局（RFC 9562）：版本 7、变体 10、48 位 Unix 毫秒时间戳（06-数据契约 总则）。 */
class UuidV7Tests {

    @Test
    void generatesVersionSevenWithVariantTen() {
        for (int index = 0; index < 1000; index++) {
            UUID uuid = UuidV7.generate();
            assertEquals(7, uuid.version(), "版本位应为 0111");
            assertEquals(2, uuid.variant(), "变体位应为 10（Leach-Salz）");
        }
    }

    @Test
    void embedsUnixMillisecondTimestamp() {
        long before = System.currentTimeMillis();
        UUID uuid = UuidV7.generate();
        long after = System.currentTimeMillis();
        long embedded = UuidV7.timestampMillis(uuid);
        assertTrue(embedded >= before && embedded <= after,
                "内嵌时间戳应在生成前后之间：" + embedded + " ∈ [" + before + ", " + after + "]");
    }

    @Test
    void timestampsAreMonotonicWithinGenerationOrder() {
        long previous = -1;
        for (int index = 0; index < 500; index++) {
            long current = UuidV7.timestampMillis(UuidV7.generate());
            assertTrue(current >= previous, "同进程生成的时间戳不应回退");
            previous = current;
        }
    }
}
