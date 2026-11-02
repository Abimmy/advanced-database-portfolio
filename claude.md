# MIT 8103 — Advanced Database Systems CA

Act as my technical assistant for implementing my Miva Open University MIT 8103 Continuous Assessment (CA).

## 1. Project Context

I have created a project folder inside the XAMPP `htdocs` directory. The folder already follows the prescribed student naming convention:

`Surname_Firstname_StudentID`

I am using:

* VS Code for development.
* Claude in VS Code for coding assistance.
* XAMPP with MariaDB/MySQL for relational database implementation.
* MongoDB for the NoSQL component, if required.
* Git and GitHub for version control and submission.

Our case study is a simulated fintech platform named **MikePay**.

MikePay manages customers, accounts, deposits, withdrawals, fund transfers, beneficiaries, and transaction audit records.

This is an individual practical portfolio, not a conventional essay.

## 2. Follow the CA Requirements

The assessment contains five practical activities:

1. **Database Design and Modelling — 7 marks**

   * Case study description.
   * ER diagram.
   * Relational schema.
   * Primary and foreign keys.
   * Constraints.
   * Normalisation explanation.

2. **Query Processing and Optimisation — 7 marks**

   * SQL queries and actual results.
   * Execution plans.
   * Indexing and optimisation evidence.
   * Brief performance analysis.

3. **Transactions and Concurrency — 7 marks**

   * Transactions using COMMIT and ROLLBACK.
   * Isolation and concurrency demonstrations.
   * Evidence of concurrency issues or their control.
   * Screenshots or output evidence.

4. **NoSQL and Advanced Data Models — 7 marks**

   * A NoSQL model based on MikePay.
   * A suitable document, key-value, column, or graph model.
   * Implementation evidence.
   * Explanation of suitability.

5. **Distributed and Cloud Database Exercise — 6 marks**

   * A practical setup or discussion based on MikePay.
   * Replication, sharding, availability, consistency, or deployment evidence.

The final documentation is worth 6 marks and must be 2–3 pages long. It should summarise the five activities and include the selected organisation, GitHub link, screenshots/evidence, individual technical reflection, and references/AI-use declaration where applicable.

## 3. Your First Task: Inspect and Prepare the Project

Before creating files or writing code:

1. Inspect the existing project folder and identify any files already present.
2. Check whether Git is installed and whether this folder is already a Git repository.
3. Check whether XAMPP's MariaDB/MySQL service is running and determine the available database version.
4. Do not assume MongoDB is installed. Check its availability separately.
5. Report your findings and identify any missing prerequisites.

Do not delete, overwrite, or modify existing files without first explaining what needs to change and why.

## 4. Create the Project Structure

Use this structure inside my existing project folder:

```text
my-student-project/
├── portfolio-1-database-design/
│   ├── sql/
│   ├── diagrams/
│   ├── evidence/
│   └── README.md
├── portfolio-2-query-optimisation/
│   ├── sql/
│   ├── execution-plans/
│   ├── evidence/
│   └── README.md
├── portfolio-3-transactions-concurrency/
│   ├── sql/
│   ├── evidence/
│   └── README.md
├── portfolio-4-nosql/
│   ├── scripts/
│   ├── sample-data/
│   ├── evidence/
│   └── README.md
├── portfolio-5-distributed-cloud/
│   ├── documentation/
│   ├── configuration/
│   ├── evidence/
│   └── README.md
├── final-documentation/
└── README.md
```

Keep the existing student-named root folder. Do not rename it to `advanced-database-portfolio`.

The directory names above are for organising the work. Individual files should have descriptive names.

## 5. Database Implementation Rules

* Use MariaDB/MySQL for the relational database activities, subject to compatibility with the installed version.
* Use a database named `mikepay_db`.
* Use synthetic sample data only.
* Never use real customer records, credentials, financial data, or confidential information.
* Use appropriate primary keys, foreign keys, data types, constraints, and indexes.
* Model monetary values using an appropriate fixed-precision decimal type rather than floating-point types.
* Implement fund transfers using database transactions.
* Explain how failed transfers are prevented from leaving account balances inconsistent.
* Consider concurrent updates, transaction isolation, and safe balance updates.
* Do not store sensitive payment credentials or real banking information.
* Do not claim that a query is optimised without comparing execution plans or other relevant evidence.

Do not assume a specific MariaDB/MySQL version. Inspect the installed version and adapt the implementation accordingly.

## 6. Evidence and Documentation

Every portfolio activity must include:

* A README explaining the objective, implementation, execution steps, and findings.
* Source scripts or configuration files where applicable.
* Genuine screenshots or captured outputs from tests actually executed.
* Brief explanations of design decisions and limitations.
* Evidence that supports the claims made in the documentation.

Do not fabricate screenshots, execution results, performance measurements, or test outcomes.

For performance testing, record the environment and test method. Distinguish estimated execution plans from actual execution measurements.

For distributed or cloud database activities, do not claim that replication, sharding, or cloud deployment was implemented unless it was genuinely configured and tested. If an activity is demonstrated conceptually rather than implemented, label it clearly and explain the limitation.

## 7. Git and GitHub

Prepare the project for a private GitHub repository.

* Check the existing Git status before making changes.
* Create an appropriate `.gitignore`.
* Exclude credentials, environment files containing secrets, database dumps containing sensitive data, and unnecessary generated files.
* Do not initialise a second Git repository if one already exists.
* Do not create a remote repository, push code, publish the project, or change remote settings without asking me first.
* Use meaningful commit messages as work progresses.
* Do not commit all five activities as completed before they have actually been implemented and tested.

## 8. Working Method

Work progressively, one activity at a time.

For every activity:

1. Explain the objective in simple terms.
2. Identify the files to create or modify.
3. Implement the solution.
4. Explain how to run it.
5. Execute tests where the environment permits.
6. Examine the results and fix errors.
7. Explain the results and relevant database concepts.
8. Capture genuine evidence.
9. Update the README.
10. Identify what I need to understand and be able to explain during technical verification.

Do not generate the entire portfolio in one step. Do not invent missing requirements. If a tool, database service, or dependency is unavailable, explain the issue before choosing an alternative.

## 9. Immediate Action

Start by inspecting the current project folder and checking the available environment.

Then report:

* The project path.
* Existing files and Git status.
* MariaDB/MySQL availability and version.
* MongoDB availability.
* Any missing prerequisites.
* The proposed project structure.

Do not begin implementing the database schema until I have reviewed your initial findings.
