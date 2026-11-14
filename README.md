# MikePay — MIT 8103 Advanced Database Systems Portfolio

Individual practical database portfolio for MIT 8103 (Miva Open University, 2026/2027, First Semester).

**Student:** Adewusi Michael (ID 301920446)

## Selected case study: MikePay

MikePay is a **simulated fintech platform**. All five portfolio activities use this one case study.

| Item | Description |
|---|---|
| Nature of the system | Retail payments platform: customer accounts, deposits, withdrawals and fund transfers |
| Users of the database | Customers, support/operations staff, auditors |
| Major data stored | Customers, accounts, transactions, transfers, beneficiaries, audit records |
| Key operations | Open an account, deposit, withdraw, transfer funds atomically, manage beneficiaries, audit balances |

All data is **synthetic**. No real customer, banking or credential data is used anywhere in this repository.

## Portfolio activities and status

| # | Activity | Marks | Status |
|---|---|---|---|
| 1 | [Database Design and Modelling](portfolio-1-database-design/) | 7 | Implemented and tested (MariaDB 10.4.32); evidence is captured command output |
| 2 | [Query Processing and Optimisation](portfolio-2-query-optimisation/) | 7 | Implemented and tested (6 experiments on 780k ledger rows); evidence is captured command output |
| 3 | [Transactions and Concurrency](portfolio-3-transactions-concurrency/) | 7 | Implemented and tested (7 COMMIT/ROLLBACK tests, 5 multi-session concurrency scenarios); evidence is captured command output |
| 4 | [NoSQL and Advanced Data Models](portfolio-4-nosql/) | 7 | Implemented and tested (MongoDB 9.0.4 document model migrated from MariaDB, 9,008-customer slice verified; index, validation and concurrency tests); evidence is captured command output |
| 5 | [Distributed and Cloud Database Exercise](portfolio-5-distributed-cloud/) | 6 | Implemented and tested: 3-member MongoDB replica set on one machine (replication, failover, write concern, lost majority, transactions, stale reads). Sharding, MariaDB replication and cloud deployment are **conceptual only, not built**; evidence is captured command output |
| - | [Final Documentation](final-documentation/) | 6 | Written (3-page Word file: [Adewusi_Michael_301920446_Documentation.docx](final-documentation/Adewusi_Michael_301920446_Documentation.docx)) with student details, individual reflection and screenshots |

Status is updated only when an activity has been implemented and tested.

## Environment

| Component | Detail |
|---|---|
| OS | Windows 11 Pro |
| Relational DBMS | MariaDB 10.4.32 (XAMPP), InnoDB, default isolation REPEATABLE-READ |
| Relational database name | `mikepay_db` |
| NoSQL | MongoDB Community 9.0.4 (local Windows service, standalone, no authentication, `127.0.0.1` only); mongosh 2.14.1; databases `mikepay_nosql` and `mikepay_nosql_sample`. Portfolio 5 adds a 3-member replica set `mikepay-rs` on ports 27018–27020 (same machine) |
| Version control | Git, GitHub (public repository: https://github.com/Abimmy/advanced-database-portfolio) |

## Repository structure

```text
├── portfolio-1-database-design/        sql/  diagrams/  evidence/
├── portfolio-2-query-optimisation/     sql/  execution-plans/  evidence/
├── portfolio-3-transactions-concurrency/  sql/  evidence/
├── portfolio-4-nosql/                  scripts/  sample-data/  evidence/
├── portfolio-5-distributed-cloud/      documentation/  configuration/  evidence/
├── final-documentation/
├── ai-use-log.md
└── README.md
```

## AI use

AI assistance (Claude Code) was used as a learning and coding aid. See [ai-use-log.md](ai-use-log.md).
