package com.cangshu;

import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

/** Requires an explicitly selected PostgreSQL instance for Spring integration tests. */
public abstract class IsolatedPostgresIntegrationTest {

    @DynamicPropertySource
    protected static void isolatedPostgres(DynamicPropertyRegistry registry) {
        String rawPort = System.getProperty("cangshu.test.db.port");
        if (rawPort == null || !rawPort.matches("[0-9]+")) {
            throw new IllegalArgumentException(
                    "Set JVM property cangshu.test.db.port to an isolated PostgreSQL port (1..65535, excluding 5432)");
        }

        final int port;
        try {
            port = Integer.parseInt(rawPort);
        } catch (NumberFormatException ex) {
            throw new IllegalArgumentException("cangshu.test.db.port is outside the valid port range", ex);
        }
        if (port < 1 || port > 65535 || port == 5432) {
            throw new IllegalArgumentException("cangshu.test.db.port must be 1..65535 and must not be 5432");
        }

        String url = "jdbc:postgresql://127.0.0.1:" + port + "/cangshu_test?currentSchema=cangshu_m1";
        registry.add("spring.datasource.url", () -> url);
    }
}
