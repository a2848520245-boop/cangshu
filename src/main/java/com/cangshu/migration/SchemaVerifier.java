package com.cangshu.migration;

import com.cangshu.config.CangshuProperties;
import jakarta.annotation.PostConstruct;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import javax.sql.DataSource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.DependsOn;
import org.springframework.stereotype.Component;

/** DEC-T3 启动门：只读脚本、manifest 与目标 catalog，绝不执行 DDL 或修复。 */
@Component
@DependsOn("writerGate")
public class SchemaVerifier {
    public static final int EXIT_CODE = 3;
    private static final Logger log = LoggerFactory.getLogger(SchemaVerifier.class);
    private static final Pattern SCRIPT = Pattern.compile("^(V\\d+)__.+\\.sql$");
    private final DataSource dataSource;
    private final CangshuProperties properties;
    public SchemaVerifier(DataSource dataSource, CangshuProperties properties) { this.dataSource=dataSource; this.properties=properties; }
    @PostConstruct public void verifyAtStartup() { verify(); }
    public void verify() {
        List<SchemaManifest.Migration> scripts = scripts();
        SchemaManifest expected = SchemaManifest.readResource();
        if (!expected.migrations().equals(scripts)) throw new MigrationVerificationException("迁移脚本集合或摘要与 manifest 不一致");
        try (Connection connection = dataSource.getConnection()) {
            connection.setReadOnly(true); verifyLedger(connection, scripts);
            SchemaManifest actual = SchemaManifest.readCatalog(connection, scripts);
            if (actual.postgresqlMajor()!=expected.postgresqlMajor() || !actual.tables().equals(expected.tables()) || !actual.indexes().equals(expected.indexes())) throw new MigrationVerificationException("schema 关键结构与 manifest 不一致");
            log.info("CANGSHU|migration|verified|scripts={}|tables={}",scripts.size(),expected.tables().size());
        } catch (SQLException ex) { throw new MigrationVerificationException("迁移只读核对无法读取数据库",ex); }
    }
    private List<SchemaManifest.Migration> scripts() {
        Path dir=Path.of(properties.getMigration().getDir()).toAbsolutePath().normalize();
        if (!Files.isDirectory(dir)||!Files.isReadable(dir)) throw new MigrationVerificationException("迁移脚本目录不可读："+dir);
        List<SchemaManifest.Migration> result=new ArrayList<>();
        try(var paths=Files.list(dir)) { paths.forEach(path->{ Matcher m=SCRIPT.matcher(path.getFileName().toString()); if(m.matches()) { if(!Files.isRegularFile(path)||!Files.isReadable(path)) throw new MigrationVerificationException("迁移脚本不可读："+path); result.add(new SchemaManifest.Migration(m.group(1),path.getFileName().toString(),sha(path))); }}); }
        catch(IOException ex) { throw new MigrationVerificationException("无法扫描迁移脚本目录："+dir,ex); }
        result.sort(Comparator.comparing(SchemaManifest.Migration::version));
        if(result.isEmpty()||result.stream().map(SchemaManifest.Migration::version).distinct().count()!=result.size()) throw new MigrationVerificationException("迁移脚本集合为空或版本重复");
        return List.copyOf(result);
    }
    private static String sha(Path path) { try(InputStream input=Files.newInputStream(path)) { MessageDigest d=MessageDigest.getInstance("SHA-256"); byte[] b=new byte[8192]; for(int n;(n=input.read(b))>=0;)d.update(b,0,n); return java.util.HexFormat.of().formatHex(d.digest()); } catch(Exception ex) { throw new MigrationVerificationException("迁移脚本不可读："+path,ex); } }
    private static void verifyLedger(Connection c,List<SchemaManifest.Migration> expected)throws SQLException { Map<String,SchemaManifest.Migration> found=new HashMap<>(); try(PreparedStatement s=c.prepareStatement("SELECT version,script_name,script_sha256 FROM cangshu_m1.schema_version");ResultSet r=s.executeQuery()){while(r.next())found.put(r.getString(1),new SchemaManifest.Migration(r.getString(1),r.getString(2),r.getString(3)));} if(found.size()!=expected.size()||!new HashSet<>(found.values()).equals(new HashSet<>(expected)))throw new MigrationVerificationException("schema_version 台账与迁移脚本不一致"); }
}
