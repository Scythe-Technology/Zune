--!strict
local TEMP_DIR = _G.__test_tempdir::string;

local sqlite = zune.sqlite;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("SQLite", function()
    test("Open/Close (Memory)", function()
        do
            local db = sqlite.open();
            db:close();
        end
        do
            local db = sqlite.open(":memory:");
            db:close();
        end
        do
            local db = sqlite.open(":MEMORY:");
            db:close();
        end
    end)

    test("Open/Close (File)", function()
        local db = sqlite.open(`{TEMP_DIR}/test.db`);
        db:close();
    end)

    test("Insert", function()
        local db = sqlite.open();
        
        db:exec("CREATE TABLE users(id TEXT PRIMARY KEY, age FLOAT)");

        do
            local query = db:query("INSERT INTO users VALUES (:id, :age)");

            expect(query:run({
                [":id"] = "a",
                [":age"] = 25,
            })).toBeNil();
            expect(query:run({
                [":id"] = "b",
                [":age"] = 27,
            })).toBeNil();
            expect(query:run({
                [":id"] = "c",
            })).toBeNil();
        end

        do
            local query = db:query("SELECT id, age FROM users");
            expect(query:all()).toBe(expect.similar({
                { id = "a", age = 25 },
                { id = "b", age = 27 },
                { id = "c", age = nil },
            }));
        end

        db:close();
    end);

    test("Count", function()
        local db = sqlite.open();
        
        db:exec("CREATE TABLE users(id TEXT PRIMARY KEY, age FLOAT)");
        db:exec(`INSERT INTO users VALUES("a", 25)`);
        db:exec(`INSERT INTO users VALUES("b", 27)`);
        db:exec(`INSERT INTO users VALUES("c", NULL)`);

        do
            local query = db:query("SELECT age FROM users");
            expect(query:run()).toBe(expect.similar({
                age = 25,
            }));
        end

        do
            local query = db:query("SELECT count(*) as count FROM users");
            expect(query:run()).toBe(expect.similar({
                count = 3,
            }));
        end

        db:close();
    end);

    test("Example", function()
        local db = sqlite.open();
        
        db:exec("CREATE TABLE users(id TEXT PRIMARY KEY, age FLOAT)");

        do
            local query = db:query("INSERT INTO users VALUES (:id, :age)");
            expect(query:run({
                [":id"] = "a",
                [":age"] = 21,
            })).toBeNil();
            expect(query:run({
                [":id"] = "b",
                [":age"] = 20,
            })).toBeNil();
            expect(query:run({
                [":id"] = "c",
            })).toBeNil();
            expect(query:run({
                [":id"] = "d",
            })).toBeNil();
        end

        do
            local query = db:query("SELECT * FROM users WHERE age >= :min")
            expect(query:run({
                [":min"] = 0,
            })).toBe(expect.similar({
                id = "a",
                age = 21,
            }));
        end
        do
            local query = db:query("SELECT * FROM users WHERE age >= :min")
            expect(query:all({
                [":min"] = 0,
            })).toBe(expect.similar({
                { id = "a", age = 21 },
                { id = "b", age = 20 },
            }));
        end
        do
            local query = db:query("SELECT * FROM users WHERE age >= :min")
            expect(query:all({
                [":min"] = 21,
            })).toBe(expect.similar({
                { id = "a", age = 21 },
            }));
        end
        do
            local query = db:query("SELECT * FROM users WHERE age >= :min")
            expect(query:all({
                [":min"] = 22,
            })).toBe(expect.similar({}));
        end
        do 
            local query = db:query("SELECT * FROM users WHERE age IS NULL")
            expect(query:all()).toBe(expect.similar({
                { id = "c", age = nil },
                { id = "d", age = nil },
            }));
        end

        db:close();
    end)
end)
