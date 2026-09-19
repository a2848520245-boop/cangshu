package com.cangshu.common.mybatis;

import java.sql.CallableStatement;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Types;
import java.util.UUID;
import org.apache.ibatis.type.BaseTypeHandler;
import org.apache.ibatis.type.JdbcType;
import org.apache.ibatis.type.MappedTypes;

/**
 * UUID ↔ PostgreSQL {@code uuid} 列的类型处理器。
 *
 * <p>《06-M1-数据契约》：五表主键／外键为 uuid 列；写入用 {@link Types#OTHER} 交由
 * PostgreSQL JDBC 驱动按 uuid 绑定，读取用 {@link ResultSet#getObject(String, Class)}。
 */
@MappedTypes(UUID.class)
public class CangshuUuidTypeHandler extends BaseTypeHandler<UUID> {

    @Override
    public void setNonNullParameter(PreparedStatement ps, int index, UUID parameter, JdbcType jdbcType)
            throws SQLException {
        ps.setObject(index, parameter, Types.OTHER);
    }

    @Override
    public UUID getNullableResult(ResultSet rs, String columnName) throws SQLException {
        return rs.getObject(columnName, UUID.class);
    }

    @Override
    public UUID getNullableResult(ResultSet rs, int columnIndex) throws SQLException {
        return rs.getObject(columnIndex, UUID.class);
    }

    @Override
    public UUID getNullableResult(CallableStatement cs, int columnIndex) throws SQLException {
        return cs.getObject(columnIndex, UUID.class);
    }
}
