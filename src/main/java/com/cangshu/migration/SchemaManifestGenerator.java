package com.cangshu.migration;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.StringReader;
import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;
import org.springframework.core.io.InputStreamResource;
import org.springframework.jdbc.datasource.init.ScriptUtils;

/**
 * 构建/验证专用：在隔离临时 PostgreSQL 17 数据库应用批准脚本，再从真实 catalog 生成 manifest。
 * 生产启动从不调用此工具，也不会执行 DDL。
 */
public final class SchemaManifestGenerator {
    private SchemaManifestGenerator() { }

    public static void main(String[] args) throws Exception {
        String adminUrl = require(args, "--admin-url=");
        String user = require(args, "--username=");
        String password = require(args, "--password=");
        Path migrations = Path.of(require(args, "--migration-dir="));
        Path output = Path.of(require(args, "--output="));
        String database = "cangshu_task30_manifest_" + UUID.randomUUID().toString().replace("-", "");
        try (Connection admin = DriverManager.getConnection(adminUrl, user, password); Statement statement = admin.createStatement()) {
            statement.execute("CREATE DATABASE " + database);
        }
        try (Connection target = DriverManager.getConnection(databaseUrl(adminUrl, database), user, password)) {
            List<SchemaManifest.Migration> ledger = new ArrayList<>();
            try (var files = Files.list(migrations)) {
                for (Path script : files.filter(Files::isRegularFile).sorted().toList()) {
                    String name = script.getFileName().toString();
                    if (!name.matches("V\\d+__.+\\.sql")) continue;
                    String sha = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(script)));
                    String sql = Files.readString(script).replace(":'script_sha256'", "'" + sha + "'");
                    ScriptUtils.executeSqlScript(target, new InputStreamResource(new java.io.ByteArrayInputStream(sql.getBytes())));
                    ledger.add(new SchemaManifest.Migration(name.substring(0, name.indexOf("__")), name, sha));
                }
            }
            SchemaManifest manifest = SchemaManifest.readCatalog(target, ledger);
            Files.createDirectories(output.toAbsolutePath().getParent());
            new ObjectMapper().writerWithDefaultPrettyPrinter().writeValue(output.toFile(), manifest);
        } finally {
            try (Connection admin = DriverManager.getConnection(adminUrl, user, password); Statement statement = admin.createStatement()) {
                statement.execute("DROP DATABASE IF EXISTS " + database);
            }
        }
    }

    private static String require(String[] args, String prefix) {
        for (String arg : args) if (arg.startsWith(prefix)) return arg.substring(prefix.length());
        throw new IllegalArgumentException("missing " + prefix);
    }

    private static String databaseUrl(String adminUrl, String database) {
        int slash = adminUrl.lastIndexOf('/');
        int query = adminUrl.indexOf('?', slash);
        return adminUrl.substring(0, slash + 1) + database + (query < 0 ? "" : adminUrl.substring(query));
    }
}