"""Generate the MikePay ER diagram (Mermaid erDiagram) from the live database.

Reads table, column and foreign-key metadata from information_schema, so the
diagram always matches the schema actually created in mikepay_db.
Uses the mysql command-line client; no third-party Python packages needed.

Usage:  python generate_er_diagram.py [output.mmd]
"""
import subprocess
import sys
from collections import OrderedDict

MYSQL = r"C:\xampp\mysql\bin\mysql.exe"
SCHEMA = "mikepay_db"


def query(sql):
    out = subprocess.run(
        [MYSQL, "-u", "root", "-N", "-B", "-e", sql],
        capture_output=True, text=True, check=True,
    ).stdout
    return [line.split("\t") for line in out.splitlines() if line]


def main(out_path):
    columns = query(
        "SELECT table_name, column_name, data_type, column_key, is_nullable "
        "FROM information_schema.columns "
        f"WHERE table_schema = '{SCHEMA}' ORDER BY table_name, ordinal_position"
    )
    fks = query(
        "SELECT k.table_name, k.column_name, k.referenced_table_name, c.is_nullable "
        "FROM information_schema.key_column_usage k "
        "JOIN information_schema.columns c "
        "  ON c.table_schema = k.table_schema AND c.table_name = k.table_name "
        "  AND c.column_name = k.column_name "
        f"WHERE k.table_schema = '{SCHEMA}' AND k.referenced_table_name IS NOT NULL "
        "ORDER BY k.referenced_table_name, k.table_name, k.column_name"
    )
    fk_columns = {(t, c) for t, c, _, _ in fks}

    tables = OrderedDict()
    for table, column, data_type, key, nullable in columns:
        marks = []
        if key == "PRI":
            marks.append("PK")
        if (table, column) in fk_columns:
            marks.append("FK")
        if key == "UNI":
            marks.append("UK")
        tables.setdefault(table, []).append((data_type, column, ", ".join(marks)))

    lines = ["erDiagram"]
    for parent_table, child_table in sorted({(p, t) for t, _, p, _ in fks}):
        for table, column, parent, nullable in fks:
            if (table, parent) != (child_table, parent_table):
                continue
            # nullable FK -> parent side is optional (|o); NOT NULL -> exactly one (||)
            parent_side = "|o" if nullable == "YES" else "||"
            label = column.replace("_account_id", "").replace("_id", "")
            lines.append(f'    {parent} {parent_side}--o{{ {table} : "{label}"')
    lines.append("")
    for table, cols in tables.items():
        lines.append(f"    {table} {{")
        for data_type, column, marks in cols:
            lines.append(f"        {data_type} {column} {marks}".rstrip())
        lines.append("    }")

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Wrote {out_path}: {len(tables)} tables, {len(fks)} foreign keys")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "mikepay_er.mmd")
