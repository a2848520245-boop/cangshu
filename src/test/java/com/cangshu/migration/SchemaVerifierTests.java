package com.cangshu.migration;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.config.CangshuProperties;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.EnumSet;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import javax.sql.DataSource;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * DEC-T3 启动门定向测试（任务 30）。
 *
 * <p><b>期望值唯一来源</b>：制品清单 {@code /db/schema-manifest-v1.json} 的真实文本——按资源对象读取，
 * 与运行期 {@link SchemaManifest#readResource()} 用的是同一份制品。夹具里没有手写的结构占位文本：
 * 台账、表、列、约束、索引五类响应全部由清单文本生成（{@link Catalog}），每个负例只做
 * 「清单文本 ＋ 逐字段微调」，所以失败只可能来自被微调的那一处。
 *
 * <p><b>查询口径</b>：夹具按 {@link SchemaManifest#readCatalog(Connection, List)} 实际发出的 SQL 逐条应答，
 * 投影列顺序逐列对齐：
 * <ul>
 *   <li>{@code SHOW server_version_num} → 清单登记的 PG 大版本（{@code 大版本 × 10000 + 补丁位}）；</li>
 *   <li>{@code pg_class} 关系清单 → 表名（{@code relname}）；</li>
 *   <li>{@code information_schema.columns} → {@code column_name,udt_name,is_nullable,column_default}
 *       （清单里的 {@code bigint} 在 PG 的 {@code udt_name} 口径下是 {@code int8}）；</li>
 *   <li>{@code pg_constraint} → {@code contype,conname,pg_get_constraintdef,列集合,引用 schema,引用表,引用列}；</li>
 *   <li>{@code pg_index} → {@code t.relname,i.relname,pg_get_indexdef}；</li>
 *   <li>{@code schema_version} → {@code version,script_name,script_sha256}。</li>
 * </ul>
 * 夹具遇到未覆盖的 SQL 直接抛错，避免运行期查询口径变化后测试悄悄空过；正例还会断言六类响应
 * 都被真实读取过。全程只经过只读代理，不连共享 PostgreSQL，也不执行任何 DDL。
 *
 * <p><b>顺序语义</b>：台账行、表清单、约束、索引都是集合语义，运行期先归一化再比较，行序打乱不影响结论
 * （见 {@link #shuffledCatalogResponseOrderStillPasses()}）。表内列序例外：运行期 SQL 带
 * {@code ORDER BY ordinal_position}，清单同样锁住列序，因此列序变化按结构漂移拒绝
 * （见 {@link #columnOrderDriftRejectsStartup()}），它不属于夹具承诺的顺序无关面。
 *
 * <p><b>状态隔离</b>：每个用例各建一份 {@link Catalog}，并把迁移脚本复制到自己的 {@link TempDir}
 * 目录；静态字段只有只读清单，用例之间不共享可变状态。
 */
class SchemaVerifierTests {

    private static final Path REPOSITORY_MIGRATION_DIR = Path.of("db", "migration");
    private static final String MANIFEST_RESOURCE = "/db/schema-manifest-v1.json";
    private static final String STRUCTURE_MISMATCH = "关键结构";
    private static final String LEDGER_MISMATCH = "台账";
    private static final String SCRIPT_SET_MISMATCH = "与 manifest 不一致";
    /** 制品清单真实文本：全部期望值的来源。 */
    private static final String MANIFEST_TEXT = readManifestText();
    private static final SchemaManifest MANIFEST = SchemaManifest.canonical(parseManifest(MANIFEST_TEXT));

    @TempDir
    Path temporaryDirectory;

    // ── 正例 ────────────────────────────────────────────────────────────────────────────────

    @Test
    void manifestTextMatchesRuntimeReader() {
        assertEquals(SchemaManifest.readResource(), MANIFEST,
                "独立解析的制品清单经同一规范化规则后必须与运行期读取结果一致");
    }

    @Test
    void matchingCatalogAndLedgerPassReadOnlyVerification() throws IOException {
        assertVerified(Catalog.fromManifest(MANIFEST), migrationDirectory("clean"));
    }

    @Test
    void shuffledCatalogResponseOrderStillPasses() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        Random random = new Random(20260922L);
        // 表清单、每张表的约束、索引、台账行都是集合语义：行序变化必须仍然通过。
        Collections.shuffle(catalog.tableNames, random);
        catalog.constraintsByTable.values().forEach(rows -> Collections.shuffle(rows, random));
        Collections.shuffle(catalog.indexes, random);
        Collections.shuffle(catalog.ledger, random);
        // 表顺序被打乱，同时改变了「每张表的列／约束查询」的应答交错顺序；
        // 表内列仍按 information_schema 的 ordinal_position 顺序应答（运行期 SQL 的排序契约）。
        assertVerified(catalog, migrationDirectory("shuffled"));
    }

    // ── 脚本与台账漂移 ──────────────────────────────────────────────────────────────────────

    @Test
    void scriptDigestDriftRejectsStartup() throws IOException {
        Path directory = migrationDirectory("script-drift");
        Path script = directory.resolve("V2__search_indexes.sql");
        Files.writeString(script, Files.readString(script) + "\\n-- 脚本被就地修订：摘要漂移\\n", StandardCharsets.UTF_8);
        assertRejected(SCRIPT_SET_MISMATCH, Catalog.fromManifest(MANIFEST), directory);
    }

    @Test
    void unregisteredExtraScriptRejectsStartup() throws IOException {
        Path directory = migrationDirectory("extra-script");
        Files.writeString(directory.resolve("V9__unregistered.sql"), "-- 未登记脚本\\n", StandardCharsets.UTF_8);
        assertRejected(SCRIPT_SET_MISMATCH, Catalog.fromManifest(MANIFEST), directory);
    }

    @Test
    void ledgerDigestDriftRejectsStartup() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        catalog.ledgerRow("V1").scriptSha256 = "0".repeat(64);
        assertRejected(LEDGER_MISMATCH, catalog, migrationDirectory("ledger-digest"));
    }

    @Test
    void missingLedgerRowRejectsStartup() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        catalog.ledger.removeIf(row -> "V2".equals(row.version));
        assertRejected(LEDGER_MISMATCH, catalog, migrationDirectory("ledger-missing"));
    }

    @Test
    void extraLedgerRowRejectsStartup() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        catalog.ledger.add(new LedgerRow("V9", "V9__unregistered.sql", "0".repeat(64)));
        assertRejected(LEDGER_MISMATCH, catalog, migrationDirectory("ledger-extra"));
    }

    // ── 结构漂移 ────────────────────────────────────────────────────────────────────────────

    @Test
    void missingCheckConstraintRejectsStartup() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        catalog.constraints("content").removeIf(row -> "content_size_bytes_check".equals(row.name));
        assertRejected(STRUCTURE_MISMATCH, catalog, migrationDirectory("check-missing"));
    }

    @Test
    void loosenedCheckExpressionRejectsStartup() throws IOException {
        Catalog loosenedSizeCheck = Catalog.fromManifest(MANIFEST);
        ConstraintRow sizeCheck = loosenedSizeCheck.constraint("content", "content_size_bytes_check");
        String originalSizeCheck = sizeCheck.definition;
        sizeCheck.definition = sizeCheck.definition.replace(">=0", ">=-1");
        assertNotEquals(originalSizeCheck, sizeCheck.definition, "负例必须真的改变 CHECK 表达式");
        assertRejected(STRUCTURE_MISMATCH, loosenedSizeCheck, migrationDirectory("check-loosened"));

        Catalog loosenedStatusCheck = Catalog.fromManifest(MANIFEST);
        ConstraintRow statusCheck = loosenedStatusCheck.constraint("content", "content_status_check");
        statusCheck.definition = statusCheck.definition.replace(",'reclaimed'::text", "");
        assertRejected(STRUCTURE_MISMATCH, loosenedStatusCheck, migrationDirectory("check-status"));
    }

    @Test
    void uniqueConstraintColumnSetChangeRejectsStartup() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        ConstraintRow unique = catalog.constraint("content", "uq_content_identity");
        unique.columns = unique.columns.replace(",size_bytes", "");
        unique.definition = unique.definition.replace(", size_bytes", "");
        assertRejected(STRUCTURE_MISMATCH, catalog, migrationDirectory("unique-drift"));
    }

    @Test
    void indexDriftRejectsStartup() throws IOException {
        Catalog removed = Catalog.fromManifest(MANIFEST);
        removed.indexes.removeIf(row -> "idx_content_digest".equals(row.name));
        assertRejected(STRUCTURE_MISMATCH, removed, migrationDirectory("index-removed"));

        Catalog methodChanged = Catalog.fromManifest(MANIFEST);
        IndexRow digestIndex = methodChanged.index("idx_content_digest");
        String originalIndex = digestIndex.definition;
        digestIndex.definition = digestIndex.definition.replace("usingbtree", "usinghash");
        assertNotEquals(originalIndex, digestIndex.definition, "负例必须真的改变索引方法");
        assertRejected(STRUCTURE_MISMATCH, methodChanged, migrationDirectory("index-method"));

        Catalog predicateChanged = Catalog.fromManifest(MANIFEST);
        IndexRow tagsIndex = predicateChanged.index("idx_resource_tags_jsonb");
        tagsIndex.definition = tagsIndex.definition.replace("jsonb_path_ops", "jsonb_ops");
        assertRejected(STRUCTURE_MISMATCH, predicateChanged, migrationDirectory("index-predicate"));

        Catalog opclassChanged = Catalog.fromManifest(MANIFEST);
        IndexRow trgmIndex = opclassChanged.index("idx_resource_name_trgm");
        trgmIndex.definition = trgmIndex.definition.replace("public.gin_trgm_ops", "gin_trgm_ops");
        assertRejected(STRUCTURE_MISMATCH, opclassChanged, migrationDirectory("index-opclass"));
    }

    @Test
    void foreignKeyTargetChangeRejectsStartup() throws IOException {
        Catalog tableChanged = Catalog.fromManifest(MANIFEST);
        ConstraintRow locationForeignKey = tableChanged.constraint("location", "location_content_id_fkey");
        locationForeignKey.referencedTable = "resource";
        locationForeignKey.definition = locationForeignKey.definition
                .replace("references cangshu_m1.content(id)", "references cangshu_m1.resource(id)");
        assertRejected(STRUCTURE_MISMATCH, tableChanged, migrationDirectory("fk-table"));

        Catalog columnChanged = Catalog.fromManifest(MANIFEST);
        ConstraintRow resourceForeignKey = columnChanged.constraint("resource", "resource_content_id_fkey");
        resourceForeignKey.referencedColumns = "content_id";
        resourceForeignKey.definition = resourceForeignKey.definition
                .replace("content(id)", "content(content_id)");
        assertRejected(STRUCTURE_MISMATCH, columnChanged, migrationDirectory("fk-column"));
    }

    @Test
    void columnTypeOrNullabilityChangeRejectsStartup() throws IOException {
        Catalog typeChanged = Catalog.fromManifest(MANIFEST);
        typeChanged.column("content", "size_bytes").udtName = "int4";
        assertRejected(STRUCTURE_MISMATCH, typeChanged, migrationDirectory("column-type"));

        Catalog nullabilityChanged = Catalog.fromManifest(MANIFEST);
        nullabilityChanged.column("resource", "mime_type").isNullable = "NO";
        assertRejected(STRUCTURE_MISMATCH, nullabilityChanged, migrationDirectory("column-nullable"));
    }

    @Test
    void columnDefaultChangeRejectsStartup() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        catalog.column("resource", "tags").columnDefault = "'{}'::jsonb";
        assertRejected(STRUCTURE_MISMATCH, catalog, migrationDirectory("column-default"));
    }

    @Test
    void extraTableOrColumnRejectsStartup() throws IOException {
        Catalog extraTable = Catalog.fromManifest(MANIFEST);
        extraTable.addTable("ghost_table");
        assertRejected(STRUCTURE_MISMATCH, extraTable, migrationDirectory("extra-table"));

        Catalog extraColumn = Catalog.fromManifest(MANIFEST);
        extraColumn.columns("content").add(new ColumnRow("extra_column", "text", "YES", null));
        assertRejected(STRUCTURE_MISMATCH, extraColumn, migrationDirectory("extra-column"));
    }

    @Test
    void droppedTableRejectsStartup() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        catalog.tableNames.remove("location");
        assertRejected(STRUCTURE_MISMATCH, catalog, migrationDirectory("dropped-table"));
    }

    @Test
    void columnOrderDriftRejectsStartup() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        // ordinal_position 变化＝表按不同列序重建；清单锁住列序，故按结构漂移拒绝。
        Collections.reverse(catalog.columns("content"));
        assertRejected(STRUCTURE_MISMATCH, catalog, migrationDirectory("column-order"));
    }

    @Test
    void postgresqlMajorMismatchRejectsStartup() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        catalog.serverVersionNum = "160004";
        assertRejected(STRUCTURE_MISMATCH, catalog, migrationDirectory("pg-major"));
    }

    // ── 制品与目录缺失 ──────────────────────────────────────────────────────────────────────

    @Test
    void missingManifestResourceRejectsStartup() throws Exception {
        Path directory = migrationDirectory("manifest-missing");
        ClassLoader loader = new ManifestHidingClassLoader(getClass().getClassLoader());
        Class<?> isolatedVerifier = loader.loadClass("com.cangshu.migration.SchemaVerifier");
        assertNotSame(SchemaVerifier.class, isolatedVerifier,
                "隔离加载器必须自己定义迁移类，隐藏资源才会对运行期代码生效");
        CangshuProperties properties = new CangshuProperties();
        properties.getMigration().setDir(directory.toString());
        Object verifier = isolatedVerifier
                .getConstructor(DataSource.class, CangshuProperties.class)
                .newInstance(dataSource(Catalog.fromManifest(MANIFEST)), properties);
        InvocationTargetException thrown = assertThrows(InvocationTargetException.class,
                () -> isolatedVerifier.getMethod("verify").invoke(verifier));
        Throwable cause = thrown.getCause();
        assertEquals("com.cangshu.migration.MigrationVerificationException", cause.getClass().getName());
        assertTrue(cause.getMessage().contains("缺少 schema manifest"),
                "异常信息应指向缺失的制品清单，实际为：" + cause.getMessage());
    }

    @Test
    void absentOrUnreadableScriptDirectoryRejectsStartup() throws IOException {
        Catalog catalog = Catalog.fromManifest(MANIFEST);
        assertRejected("目录不可读", catalog, temporaryDirectory.resolve("absent"));

        Path unreadable = Files.createDirectory(temporaryDirectory.resolve("unreadable"));
        Files.createDirectory(unreadable.resolve("V1__init.sql"));
        assertRejected("脚本不可读", catalog, unreadable);

        Path empty = Files.createDirectory(temporaryDirectory.resolve("empty"));
        assertRejected("为空或版本重复", catalog, empty);
    }

    // ── 夹具与断言 ──────────────────────────────────────────────────────────────────────────

    /** 正例：核对通过，且六类查询面确实都被读取过。 */
    private static void assertVerified(Catalog catalog, Path migrationDirectory) {
        assertDoesNotThrow(() -> verifier(catalog, migrationDirectory).verify(),
                "目录、台账与结构都来自同一份清单，只读核对必须通过");
        assertEquals(EnumSet.allOf(Surface.class), catalog.queried,
                "正例必须真实覆盖全部查询面，否则测试会空过");
    }

    /** 负例：异常类型必须是启动门的退出码 3 异常，且信息落在指定类别上。 */
    private static void assertRejected(String expectedCategory, Catalog catalog, Path migrationDirectory) {
        MigrationVerificationException thrown = assertThrows(MigrationVerificationException.class,
                () -> verifier(catalog, migrationDirectory).verify(),
                "该漂移必须被只读核对拒绝");
        assertTrue(thrown.getMessage() != null && thrown.getMessage().contains(expectedCategory),
                "异常信息应指向「" + expectedCategory + "」，实际为：" + thrown.getMessage());
    }

    private static SchemaVerifier verifier(Catalog catalog, Path migrationDirectory) {
        CangshuProperties properties = new CangshuProperties();
        properties.getMigration().setDir(migrationDirectory.toString());
        return new SchemaVerifier(dataSource(catalog), properties);
    }

    /** 复制真实 db/migration 脚本到本用例独占的临时目录；摘要必须与清单一致，否则正例会失败。 */
    private Path migrationDirectory(String name) throws IOException {
        assertTrue(Files.isDirectory(REPOSITORY_MIGRATION_DIR),
                "测试应在代码仓根运行：找不到 " + REPOSITORY_MIGRATION_DIR.toAbsolutePath());
        Path destination = Files.createDirectory(temporaryDirectory.resolve(name));
        try (var sources = Files.list(REPOSITORY_MIGRATION_DIR)) {
            for (Path source : sources.toList()) {
                Files.copy(source, destination.resolve(source.getFileName().toString()));
            }
        }
        return destination;
    }

    private static String readManifestText() {
        try (InputStream input = SchemaVerifierTests.class.getResourceAsStream(MANIFEST_RESOURCE)) {
            if (input == null) {
                throw new IllegalStateException("测试类路径缺少制品清单 " + MANIFEST_RESOURCE);
            }
            return new String(input.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException exception) {
            throw new IllegalStateException("无法读取制品清单 " + MANIFEST_RESOURCE, exception);
        }
    }

    private static SchemaManifest parseManifest(String text) {
        try {
            return new ObjectMapper().readValue(text, SchemaManifest.class);
        } catch (IOException exception) {
            throw new IllegalStateException("制品清单文本不是合法 JSON", exception);
        }
    }

    /** 运行期 readCatalog 会查询的六个面；用来防止夹具被静默绕过。 */
    private enum Surface { SERVER_VERSION, TABLE_LIST, COLUMNS, CONSTRAINTS, INDEXES, LEDGER }

    /**
     * 由清单文本生成的 JDBC 只读夹具。行记录的可变字段就是「逐字段微调」的入口，
     * {@code values()} 的列顺序与运行期 SQL 的投影顺序逐列对齐。
     */
    private static final class Catalog {

        private final Set<Surface> queried = new LinkedHashSet<>();
        private final List<String> tableNames = new ArrayList<>();
        private final Map<String, List<ColumnRow>> columnsByTable = new LinkedHashMap<>();
        private final Map<String, List<ConstraintRow>> constraintsByTable = new LinkedHashMap<>();
        private final List<IndexRow> indexes = new ArrayList<>();
        private final List<LedgerRow> ledger = new ArrayList<>();
        private String serverVersionNum;

        static Catalog fromManifest(SchemaManifest manifest) {
            Catalog catalog = new Catalog();
            catalog.serverVersionNum = String.valueOf(manifest.postgresqlMajor() * 10_000 + 5);
            for (SchemaManifest.Migration migration : manifest.migrations()) {
                catalog.ledger.add(new LedgerRow(migration.version(), migration.scriptName(), migration.scriptSha256()));
            }
            for (SchemaManifest.Table table : manifest.tables()) {
                catalog.tableNames.add(table.name());
                List<ColumnRow> columns = new ArrayList<>();
                for (SchemaManifest.Column column : table.columns()) {
                    columns.add(new ColumnRow(column.name(), udtName(column.type()), column.nullable() ? "YES" : "NO",
                            column.defaultDefinition()));
                }
                catalog.columnsByTable.put(table.name(), columns);
                List<ConstraintRow> constraints = new ArrayList<>();
                for (SchemaManifest.Constraint constraint : table.constraints()) {
                    constraints.add(new ConstraintRow(constraint.type(), constraint.name(), constraint.definition(),
                            join(constraint.columns()), orEmpty(constraint.referencedSchema()),
                            orEmpty(constraint.referencedTable()), join(constraint.referencedColumns())));
                }
                catalog.constraintsByTable.put(table.name(), constraints);
            }
            for (SchemaManifest.Index index : manifest.indexes()) {
                catalog.indexes.add(new IndexRow(index.tableName(), index.name(), index.definition()));
            }
            return catalog;
        }

        void addTable(String table) {
            tableNames.add(table);
            columnsByTable.put(table, new ArrayList<>());
            constraintsByTable.put(table, new ArrayList<>());
        }

        List<ColumnRow> columns(String table) {
            List<ColumnRow> rows = columnsByTable.get(table);
            if (rows == null) throw new IllegalStateException("清单里没有表 " + table);
            return rows;
        }

        ColumnRow column(String table, String name) {
            return columns(table).stream().filter(row -> name.equals(row.name)).findFirst()
                    .orElseThrow(() -> new IllegalStateException("清单里没有列 " + table + "." + name));
        }

        List<ConstraintRow> constraints(String table) {
            List<ConstraintRow> rows = constraintsByTable.get(table);
            if (rows == null) throw new IllegalStateException("清单里没有表 " + table);
            return rows;
        }

        ConstraintRow constraint(String table, String name) {
            return constraints(table).stream().filter(row -> name.equals(row.name)).findFirst()
                    .orElseThrow(() -> new IllegalStateException("清单里没有约束 " + table + "." + name));
        }

        IndexRow index(String name) {
            return indexes.stream().filter(row -> name.equals(row.name)).findFirst()
                    .orElseThrow(() -> new IllegalStateException("清单里没有索引 " + name));
        }

        LedgerRow ledgerRow(String version) {
            return ledger.stream().filter(row -> version.equals(row.version)).findFirst()
                    .orElseThrow(() -> new IllegalStateException("清单里没有迁移版本 " + version));
        }

        private List<List<String>> tableNameRows() {
            List<List<String>> rows = new ArrayList<>();
            tableNames.forEach(name -> rows.add(List.of(name)));
            return rows;
        }

        private List<List<String>> columnRows(String table) {
            return rows(columns(table));
        }

        private List<List<String>> constraintRows(String table) {
            return rows(constraints(table));
        }

        private List<List<String>> indexRows() {
            return rows(indexes);
        }

        private List<List<String>> ledgerRows() {
            return rows(ledger);
        }

        private static List<List<String>> rows(List<? extends FixtureRow> rows) {
            List<List<String>> values = new ArrayList<>();
            rows.forEach(row -> values.add(row.values()));
            return values;
        }
    }

    /** 夹具回应答的行；{@code values()} 顺序＝运行期 SQL 投影顺序。 */
    private interface FixtureRow {
        List<String> values();
    }

    private static final class LedgerRow implements FixtureRow {
        private final String version;
        private String scriptName;
        private String scriptSha256;

        LedgerRow(String version, String scriptName, String scriptSha256) {
            this.version = version;
            this.scriptName = scriptName;
            this.scriptSha256 = scriptSha256;
        }

        @Override
        public List<String> values() {
            return Arrays.asList(version, scriptName, scriptSha256);
        }
    }

    private static final class ColumnRow implements FixtureRow {
        private final String name;
        private String udtName;
        private String isNullable;
        private String columnDefault;

        ColumnRow(String name, String udtName, String isNullable, String columnDefault) {
            this.name = name;
            this.udtName = udtName;
            this.isNullable = isNullable;
            this.columnDefault = columnDefault;
        }

        @Override
        public List<String> values() {
            return Arrays.asList(name, udtName, isNullable, columnDefault);
        }
    }

    private static final class ConstraintRow implements FixtureRow {
        private final String type;
        private final String name;
        private String definition;
        private String columns;
        private String referencedSchema;
        private String referencedTable;
        private String referencedColumns;

        ConstraintRow(String type, String name, String definition, String columns, String referencedSchema,
                String referencedTable, String referencedColumns) {
            this.type = type;
            this.name = name;
            this.definition = definition;
            this.columns = columns;
            this.referencedSchema = referencedSchema;
            this.referencedTable = referencedTable;
            this.referencedColumns = referencedColumns;
        }

        @Override
        public List<String> values() {
            return Arrays.asList(type, name, definition, columns, referencedSchema, referencedTable, referencedColumns);
        }
    }

    private static final class IndexRow implements FixtureRow {
        private final String tableName;
        private final String name;
        private String definition;

        IndexRow(String tableName, String name, String definition) {
            this.tableName = tableName;
            this.name = name;
            this.definition = definition;
        }

        @Override
        public List<String> values() {
            return Arrays.asList(tableName, name, definition);
        }
    }

    // ── 只读 JDBC 代理 ──────────────────────────────────────────────────────────────────────

    private static DataSource dataSource(Catalog catalog) {
        return (DataSource) Proxy.newProxyInstance(SchemaVerifierTests.class.getClassLoader(),
                new Class<?>[] {DataSource.class}, (proxy, method, arguments) ->
                        "getConnection".equals(method.getName()) ? connection(catalog) : defaultValue(method));
    }

    private static Connection connection(Catalog catalog) {
        return (Connection) Proxy.newProxyInstance(SchemaVerifierTests.class.getClassLoader(),
                new Class<?>[] {Connection.class}, (proxy, method, arguments) ->
                        "prepareStatement".equals(method.getName())
                                ? statement(catalog, (String) arguments[0])
                                : defaultValue(method));
    }

    private static PreparedStatement statement(Catalog catalog, String sql) {
        Map<Integer, String> parameters = new HashMap<>();
        return (PreparedStatement) Proxy.newProxyInstance(SchemaVerifierTests.class.getClassLoader(),
                new Class<?>[] {PreparedStatement.class}, (proxy, method, arguments) -> {
                    switch (method.getName()) {
                        case "setString":
                            parameters.put((Integer) arguments[0], (String) arguments[1]);
                            return null;
                        case "execute":
                            return false;
                        case "executeQuery":
                            return resultSet(rowsFor(catalog, sql, parameters));
                        default:
                            return defaultValue(method);
                    }
                });
    }

    private static ResultSet resultSet(List<List<String>> rows) {
        return (ResultSet) Proxy.newProxyInstance(SchemaVerifierTests.class.getClassLoader(),
                new Class<?>[] {ResultSet.class}, new java.lang.reflect.InvocationHandler() {
                    private int cursor = -1;

                    @Override
                    public Object invoke(Object proxy, Method method, Object[] arguments) {
                        switch (method.getName()) {
                            case "next":
                                return ++cursor < rows.size();
                            case "getString":
                                if (!(arguments[0] instanceof Integer column)) {
                                    throw new IllegalStateException("夹具只支持按列号取列：" + arguments[0]);
                                }
                                return rows.get(cursor).get(column - 1);
                            default:
                                return defaultValue(method);
                        }
                    }
                });
    }

    /** 按运行期实际 SQL 分派应答；未覆盖的查询直接失败，防止查询口径变化后测试空过。 */
    private static List<List<String>> rowsFor(Catalog catalog, String sql, Map<Integer, String> parameters) {
        String query = sql.toLowerCase(Locale.ROOT);
        if (query.contains("schema_version")) {
            catalog.queried.add(Surface.LEDGER);
            return catalog.ledgerRows();
        }
        if (query.contains("server_version_num")) {
            catalog.queried.add(Surface.SERVER_VERSION);
            return List.of(List.of(catalog.serverVersionNum));
        }
        if (query.contains("information_schema.columns")) {
            catalog.queried.add(Surface.COLUMNS);
            return catalog.columnRows(parameters.get(2));
        }
        if (query.contains("pg_constraint con")) {
            catalog.queried.add(Surface.CONSTRAINTS);
            return catalog.constraintRows(parameters.get(2));
        }
        if (query.contains("from pg_index")) {
            catalog.queried.add(Surface.INDEXES);
            return catalog.indexRows();
        }
        if (query.contains("from pg_class c")) {
            catalog.queried.add(Surface.TABLE_LIST);
            return catalog.tableNameRows();
        }
        throw new IllegalStateException("夹具未覆盖该查询，疑似运行期查询口径已变化：" + sql);
    }

    private static Object defaultValue(Method method) {
        Class<?> type = method.getReturnType();
        if (void.class.equals(type) || !type.isPrimitive()) {
            return null;
        }
        if (boolean.class.equals(type)) {
            return false;
        }
        if (char.class.equals(type)) {
            return '\0';
        }
        return 0;
    }

    private static String udtName(String manifestType) {
        return "bigint".equals(manifestType) ? "int8" : manifestType;
    }

    private static String join(List<String> values) {
        return values == null ? "" : String.join(",", values);
    }

    private static String orEmpty(String value) {
        return value == null ? "" : value;
    }

    /** 隐藏制品清单资源的隔离类加载器：证明「清单缺失」同样会被启动门拒绝。 */
    private static final class ManifestHidingClassLoader extends ClassLoader {

        private static final String HIDDEN_RESOURCE = "db/schema-manifest-v1.json";

        ManifestHidingClassLoader(ClassLoader parent) {
            super(parent);
        }

        @Override
        protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
            if (!name.startsWith("com.cangshu.migration.")) {
                return super.loadClass(name, resolve);
            }
            synchronized (getClassLoadingLock(name)) {
                Class<?> loaded = findLoadedClass(name);
                if (loaded == null) {
                    byte[] bytes = classBytes(name);
                    loaded = defineClass(name, bytes, 0, bytes.length);
                }
                if (resolve) {
                    resolveClass(loaded);
                }
                return loaded;
            }
        }

        @Override
        public InputStream getResourceAsStream(String name) {
            return name.endsWith(HIDDEN_RESOURCE) ? null : getParent().getResourceAsStream(name);
        }

        @Override
        public URL getResource(String name) {
            return name.endsWith(HIDDEN_RESOURCE) ? null : getParent().getResource(name);
        }

        private byte[] classBytes(String name) throws ClassNotFoundException {
            try (InputStream input = getParent().getResourceAsStream(name.replace('.', '/') + ".class")) {
                if (input == null) {
                    throw new ClassNotFoundException(name);
                }
                ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                input.transferTo(buffer);
                return buffer.toByteArray();
            } catch (IOException exception) {
                throw new ClassNotFoundException(name, exception);
            }
        }
    }
}
