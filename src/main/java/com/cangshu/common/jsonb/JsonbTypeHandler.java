package com.cangshu.common.jsonb;

import java.sql.CallableStatement;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import org.apache.ibatis.type.BaseTypeHandler;
import org.apache.ibatis.type.JdbcType;
import org.postgresql.util.PGobject;

/**
 * 文本 ↔ PostgreSQL {@code jsonb} 列的类型处理器（resource.tags，M1 允许简化结构）。
 *
 * <p>写入以 {@link PGobject}（type=jsonb）绑定，避免把 jsonb 当 varchar 发送；读取按文本原样返回。
 * 注意：本类<b>不放在</b> {@code type-handlers-package} 扫描包内——String→jsonb 一旦全局注册，
 * 会把所有 String 参数都当 jsonb 绑定（text = jsonb 报错）；它只经
 * {@code @TableField(typeHandler=...)} 按列显式引用。
 */
public class JsonbTypeHandler extends BaseTypeHandler<String> {

    @Override
    public void setNonNullParameter(PreparedStatement ps, int index, String parameter, JdbcType jdbcType)
            throws SQLException {
        PGobject jsonb = new PGobject();
        jsonb.setType("jsonb");
        jsonb.setValue(parameter);
        ps.setObject(index, jsonb);
    }

    @Override
    public String getNullableResult(ResultSet rs, String columnName) throws SQLException {
        return rs.getString(columnName);
    }

    @Override
    public String getNullableResult(ResultSet rs, int columnIndex) throws SQLException {
        return rs.getString(columnIndex);
    }

    @Override
    public String getNullableResult(CallableStatement cs, int columnIndex) throws SQLException {
        return cs.getString(columnIndex);
    }
}
