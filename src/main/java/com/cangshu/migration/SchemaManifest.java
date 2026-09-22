package com.cangshu.migration;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.io.InputStream;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

/** 由隔离 PG17 实例反编译生成的 M1 schema 基线；运行时仅读取和比较。 */
public record SchemaManifest(int formatVersion, int postgresqlMajor, List<Migration> migrations,
        List<Table> tables, List<Index> indexes) {

    public static final int FORMAT_VERSION = 1;
    public static final String SCHEMA = "cangshu_m1";
    private static final ObjectMapper JSON = new ObjectMapper();

    public record Migration(String version, String scriptName, String scriptSha256) {
    }

    public record Table(String name, List<Column> columns, List<Constraint> constraints) {
    }

    public record Column(String name, String type, boolean nullable, String defaultDefinition) {
    }

    /** columns 和 referenced* 由 pg_constraint 元数据提取，definition 用 pg_get_constraintdef 反编译。 */
    public record Constraint(String type, String name, List<String> columns, String referencedSchema,
            String referencedTable, List<String> referencedColumns, String definition) {
    }

    /** definition 用 pg_get_indexdef 反编译，包含索引方法、列、opclass 和谓词。 */
    public record Index(String tableName, String name, String definition) {
    }

    public static SchemaManifest readResource() {
        try (InputStream input = SchemaManifest.class.getResourceAsStream("/db/schema-manifest-v1.json")) {
            if (input == null) {
                throw new MigrationVerificationException("制品缺少 schema manifest：/db/schema-manifest-v1.json");
            }
            SchemaManifest manifest = JSON.readValue(input, new TypeReference<>() {
            });
            if (manifest.formatVersion != FORMAT_VERSION || manifest.postgresqlMajor != 17) {
                throw new MigrationVerificationException("schema manifest 格式或 PostgreSQL 大版本不受支持");
            }
            return canonical(manifest);
        } catch (IOException exception) {
            throw new MigrationVerificationException("无法读取 schema manifest", exception);
        }
    }

    public static SchemaManifest readCatalog(Connection connection, List<Migration> migrations) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("SET search_path TO pg_catalog")) {
            statement.execute();
        }
        int major;
        try (PreparedStatement statement = connection.prepareStatement("SHOW server_version_num"); ResultSet rows = statement.executeQuery()) {
            rows.next();
            major = Integer.parseInt(rows.getString(1)) / 10000;
        }
        List<Table> tables = readTables(connection);
        List<Index> indexes = readIndexes(connection);
        return canonical(new SchemaManifest(FORMAT_VERSION, major, migrations, tables, indexes));
    }

    private static List<Table> readTables(Connection connection) throws SQLException {
        List<String> names = new ArrayList<>();
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                        + "WHERE n.nspname=? AND c.relkind='r' ORDER BY relname")) {
            statement.setString(1, SCHEMA);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) names.add(rows.getString(1));
            }
        }
        List<Table> tables = new ArrayList<>();
        for (String name : names) tables.add(new Table(name, readColumns(connection, name), readConstraints(connection, name)));
        return tables;
    }

    private static List<Column> readColumns(Connection connection, String table) throws SQLException {
        List<Column> columns = new ArrayList<>();
        String sql = "SELECT column_name, udt_name, is_nullable, column_default FROM information_schema.columns "
                + "WHERE table_schema=? AND table_name=? ORDER BY ordinal_position";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, SCHEMA); statement.setString(2, table);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) columns.add(new Column(rows.getString(1), normalizeType(rows.getString(2)),
                        "YES".equals(rows.getString(3)), normalizeDefinition(rows.getString(4))));
            }
        }
        return columns;
    }

    private static List<Constraint> readConstraints(Connection connection, String table) throws SQLException {
        List<Constraint> constraints = new ArrayList<>();
        String sql = "SELECT con.contype::text, con.conname, pg_get_constraintdef(con.oid), "
                + "coalesce(array_to_string(ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(attnum,ord) "
                + "JOIN pg_attribute a ON a.attrelid=con.conrelid AND a.attnum=k.attnum ORDER BY k.ord), ','), ''), "
                + "coalesce(tn.nspname,''), coalesce(tr.relname,''), "
                + "coalesce(array_to_string(ARRAY(SELECT a.attname FROM unnest(con.confkey) WITH ORDINALITY k(attnum,ord) "
                + "JOIN pg_attribute a ON a.attrelid=con.confrelid AND a.attnum=k.attnum ORDER BY k.ord), ','), '') "
                + "FROM pg_constraint con JOIN pg_class r ON r.oid=con.conrelid JOIN pg_namespace n ON n.oid=r.relnamespace "
                + "LEFT JOIN pg_class tr ON tr.oid=con.confrelid LEFT JOIN pg_namespace tn ON tn.oid=tr.relnamespace "
                + "WHERE n.nspname=? AND r.relname=? ORDER BY con.contype, con.conname";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, SCHEMA); statement.setString(2, table);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) constraints.add(new Constraint(rows.getString(1), rows.getString(2), split(rows.getString(4)),
                        emptyToNull(rows.getString(5)), emptyToNull(rows.getString(6)), split(rows.getString(7)),
                        normalizeDefinition(rows.getString(3))));
            }
        }
        return constraints;
    }

    private static List<Index> readIndexes(Connection connection) throws SQLException {
        List<Index> indexes = new ArrayList<>();
        String sql = "SELECT t.relname, i.relname, pg_get_indexdef(i.oid) FROM pg_index x "
                + "JOIN pg_class i ON i.oid=x.indexrelid JOIN pg_class t ON t.oid=x.indrelid "
                + "JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname=? ORDER BY t.relname, i.relname";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, SCHEMA);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) indexes.add(new Index(rows.getString(1), rows.getString(2), normalizeDefinition(rows.getString(3))));
            }
        }
        return indexes;
    }

    public static String normalizeDefinition(String value) {
        if (value == null) return null;
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", "").trim().replace("\"", "");
    }

    private static String normalizeType(String type) {
        return switch (type.toLowerCase(Locale.ROOT)) { case "int8" -> "bigint"; case "timestamptz" -> "timestamptz"; default -> type.toLowerCase(Locale.ROOT); };
    }

    private static List<String> split(String value) { return value == null || value.isBlank() ? List.of() : List.of(value.split(",")); }
    private static String emptyToNull(String value) { return value == null || value.isBlank() ? null : value; }

    static SchemaManifest canonical(SchemaManifest manifest) {
        List<Migration> migrations = manifest.migrations.stream().sorted(Comparator.comparing(Migration::version)).toList();
        List<Table> tables = manifest.tables.stream().map(table -> new Table(table.name,
                table.columns.stream().map(column -> new Column(column.name, normalizeType(column.type), column.nullable,
                        normalizeDefinition(column.defaultDefinition))).toList(),
                table.constraints.stream().map(c -> new Constraint(c.type, c.name, List.copyOf(c.columns), c.referencedSchema,
                        c.referencedTable, List.copyOf(c.referencedColumns), normalizeDefinition(c.definition)))
                        .sorted(Comparator.comparing(Constraint::type).thenComparing(Constraint::name)).toList()))
                .sorted(Comparator.comparing(Table::name)).toList();
        List<Index> indexes = manifest.indexes.stream().map(i -> new Index(i.tableName, i.name, normalizeDefinition(i.definition)))
                .sorted(Comparator.comparing(Index::tableName).thenComparing(Index::name)).toList();
        return new SchemaManifest(manifest.formatVersion, manifest.postgresqlMajor, migrations, tables, indexes);
    }
}
