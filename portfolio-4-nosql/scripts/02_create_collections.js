// Portfolio 4 - step 2: create the MikePay collections with schema validation.
//
// Run:  mongosh --file 02_create_collections.js --eval "var DB_NAME='mikepay_nosql'"
//
// MongoDB is schema-flexible, but a financial collection still needs guard rails.
// $jsonSchema validators below reject documents with a wrong type (for example a
// floating-point balance), a missing required field or an unknown enum value.
// Money is always BSON Decimal128 ("decimal"), the equivalent of DECIMAL(15,2).
// Fields NOT listed under "required" (for example `metadata`, `transfer`) stay optional
// and free-form, which is where the flexible-schema benefit comes from.

const dbName = (typeof DB_NAME !== "undefined") ? DB_NAME : "mikepay_nosql";
const d = db.getSiblingDB(dbName);
if (!dbName.startsWith("mikepay_nosql")) throw new Error("Refusing to drop a database not named mikepay_nosql*: " + dbName);
print(`Database: ${dbName}`);
d.dropDatabase();   // re-runnable: start from empty collections

const money = { bsonType: "decimal" };
const date = { bsonType: "date" };

const validators = {
  customers: {
    bsonType: "object",
    required: ["_id", "first_name", "last_name", "email", "phone", "status", "created_at", "accounts", "beneficiaries"],
    properties: {
      _id: { bsonType: "int" },
      first_name: { bsonType: "string", maxLength: 50 },
      last_name: { bsonType: "string", maxLength: 50 },
      email: { bsonType: "string", pattern: "^[^@\\s]+@[^@\\s]+$", maxLength: 100 },
      phone: { bsonType: "string", maxLength: 20 },
      status: { enum: ["ACTIVE", "SUSPENDED", "CLOSED"] },
      created_at: date,
      accounts: {
        bsonType: "array",
        items: {
          bsonType: "object",
          required: ["account_id", "account_number", "account_type", "currency", "balance", "status", "opened_at"],
          properties: {
            account_id: { bsonType: "int" },
            account_number: { bsonType: "string", pattern: "^[0-9]{10}$" },
            account_type: { enum: ["SAVINGS", "CURRENT"] },
            currency: { bsonType: "string", pattern: "^[A-Z]{3}$" },
            balance: money,
            status: { enum: ["ACTIVE", "FROZEN", "CLOSED"] },
            opened_at: date
          }
        }
      },
      beneficiaries: {
        bsonType: "array",
        items: {
          bsonType: "object",
          required: ["beneficiary_id", "nickname", "account_number", "added_at"],
          properties: {
            beneficiary_id: { bsonType: "int" },
            nickname: { bsonType: "string", maxLength: 50 },
            account_number: { bsonType: "string", pattern: "^[0-9]{10}$" },
            account_holder: { bsonType: "string" },
            added_at: date
          }
        }
      }
    }
  },
  transactions: {
    bsonType: "object",
    required: ["_id", "account_id", "account_number", "customer_id", "type", "amount", "balance_after", "created_at"],
    properties: {
      _id: { bsonType: ["int", "long"] },
      account_id: { bsonType: "int" },
      account_number: { bsonType: "string", pattern: "^[0-9]{10}$" },
      customer_id: { bsonType: "int" },
      type: { enum: ["DEPOSIT", "WITHDRAWAL", "TRANSFER_DEBIT", "TRANSFER_CREDIT"] },
      amount: money,            // > 0 is also enforced below with $jsonSchema "minimum"
      balance_after: money,
      description: { bsonType: "string", maxLength: 255 },
      created_at: date,
      transfer: {
        bsonType: "object",
        required: ["transfer_id", "reference"],
        properties: { transfer_id: { bsonType: ["int", "long"] }, reference: { bsonType: "string" },
                      counterparty_account_number: { bsonType: "string" } }
      },
      metadata: { bsonType: "object" }
    }
  },
  transfers: {
    bsonType: "object",
    required: ["_id", "reference", "source", "destination", "amount", "status", "created_at"],
    properties: {
      _id: { bsonType: ["int", "long"] },
      reference: { bsonType: "string", maxLength: 30 },
      source: { bsonType: "object", required: ["account_id", "account_number"] },
      destination: { bsonType: "object", required: ["account_id", "account_number"] },
      amount: money,
      status: { enum: ["PENDING", "COMPLETED", "FAILED", "REVERSED"] },
      failure_reason: { bsonType: "string" },
      created_at: date,
      completed_at: date
    }
  },
  audit_events: {
    bsonType: "object",
    required: ["_id", "account_id", "action", "new_balance", "changed_by", "changed_at"],
    properties: {
      _id: { bsonType: ["int", "long"] },
      account_id: { bsonType: "int" },
      action: { enum: ["ACCOUNT_OPENED", "BALANCE_CHANGED"] },
      old_balance: money,
      new_balance: money,
      changed_by: { bsonType: "string" },
      changed_at: date
    }
  }
};

// amount must be strictly positive (mirrors CHECK (amount > 0) in MariaDB)
for (const c of ["transactions", "transfers"]) {
  validators[c].properties.amount = { bsonType: "decimal", minimum: NumberDecimal("0.01") };
}

for (const [name, schema] of Object.entries(validators)) {
  d.createCollection(name, { validator: { $jsonSchema: schema }, validationLevel: "strict", validationAction: "error" });
  print(`created collection ${name} with $jsonSchema validator (strict, action=error)`);
}

// Indexes that enforce business rules (unique) - performance indexes are added separately in 06.
d.customers.createIndex({ email: 1 }, { unique: true, name: "uq_customers_email" });
d.customers.createIndex({ "accounts.account_number": 1 }, { unique: true, name: "uq_customers_account_number" });
d.transfers.createIndex({ reference: 1 }, { unique: true, name: "uq_transfers_reference" });

print("\nCollections:");
printjson(d.getCollectionInfos().map(c => ({ name: c.name, validationLevel: c.options.validationLevel, validationAction: c.options.validationAction })));
print("Indexes created so far:");
for (const c of ["customers", "transactions", "transfers", "audit_events"]) {
  print(`  ${c}: ` + d[c].getIndexes().map(i => i.name).join(", "));
}
