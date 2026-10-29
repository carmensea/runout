import type { ReactNode } from 'react';
import styles from './DataTable.module.css';

export interface Column<Row> {
  header: string;
  cell(row: Row): ReactNode;
  numeric?: boolean;
}

interface Props<Row> {
  caption: string;
  columns: ReadonlyArray<Column<NoInfer<Row>>>;
  rows: readonly Row[];
  rowKey(row: NoInfer<Row>): string;
  /** Hidden tables are the accessible alternative for charts without a visible table toggle. */
  hidden?: boolean;
  maxHeight?: number;
}

/** Tabular alternative for a chart. */
export function DataTable<Row>({ caption, columns, rows, rowKey, hidden, maxHeight }: Props<Row>) {
  const table = (
    <table className={styles.table}>
      <caption className="sr-only">{caption}</caption>
      <thead>
        <tr>
          {columns.map((c) => (
            <th key={c.header} scope="col" className={c.numeric ? styles.num : undefined}>{c.header}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={rowKey(r)}>
            {columns.map((c, i) =>
              i === 0 ? (
                <th key={c.header} scope="row" style={{ fontWeight: 400, fontFamily: 'inherit', fontSize: 'inherit', textTransform: 'none', letterSpacing: 0, color: 'var(--fg)', borderTop: '1px solid var(--ln)' }}>
                  {c.cell(r)}
                </th>
              ) : (
                <td key={c.header} className={c.numeric ? styles.num : undefined}>{c.cell(r)}</td>
              ),
            )}
          </tr>
        ))}
      </tbody>
    </table>
  );
  if (hidden) return <div className="sr-only">{table}</div>;
  return <div className={styles.wrap} style={maxHeight ? { maxHeight, overflowY: 'auto' } : undefined}>{table}</div>;
}
