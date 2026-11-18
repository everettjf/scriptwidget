import test from "node:test";
import assert from "node:assert/strict";
import { dataAPICatalog } from "../src/dataAPICatalog.js";
import { platformColumns, platformRow, platformSentence, platformSupport } from "../src/platformSupport.js";

test("every API is in one row and every row answers for every system", () => {
  const names = platformSupport.flatMap((row) => row.apis);
  assert.equal(new Set(names).size, names.length);
  for (const row of platformSupport) {
    for (const column of platformColumns) {
      const value = row[column.id];
      assert.ok(typeof value === "boolean" || (typeof value === "string" && value.length > 0), `${row.apis[0]} ${column.id}`);
    }
  }
});

test("the Apple columns agree with the data API catalog", () => {
  for (const item of dataAPICatalog) {
    const row = platformRow(`$${item.group}`);
    assert.ok(row, item.group);
    assert.equal(row.ios !== false, item.platforms.includes("ios"), item.id);
    assert.equal(row.macos !== false, item.platforms.includes("macos"), item.id);
  }
});

test("a row reads as a sentence", () => {
  assert.deepEqual(platformSentence(platformRow("$health")), {
    yes: "iPhone and iPad, Android (Health Connect; no ring goals or stand time)",
    no: "Mac, Windows, Linux",
  });
  assert.deepEqual(platformSentence(platformRow("$storage")), {
    yes: "iPhone and iPad, Mac, Android, Windows, Linux",
    no: "",
  });
});
