// Counts TypeScript diagnostic codes per thousand band. Run: node ts_codes.js <path-to-typescript>
const ts = require(process.argv[2] || "typescript");
const all = Object.values(ts.Diagnostics);
const bands = {};
for (const d of all) bands[Math.floor(d.code / 1000)] = (bands[Math.floor(d.code / 1000)] || 0) + 1;
console.log("typescript", ts.version, "diagnostics", all.length);
console.log("per thousand band", JSON.stringify(bands));
console.log("TS2345", JSON.stringify(all.find(d => d.code === 2345)));
