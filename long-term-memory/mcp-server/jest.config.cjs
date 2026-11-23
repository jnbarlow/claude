/** @type {import('jest').Config} */
module.exports = {
  preset: "ts-jest/presets/default-esm",
  testEnvironment: "node",
  extensionsToTreatAsEsm: [".ts"],
  moduleNameMapper: {
    "^(\\.{1,2}/.*)\\.js$": "$1",
  },
  transform: {
    "^.+\\.tsx?$": [
      "ts-jest",
      {
        useESM: true,
        tsconfig: {
          // Tests import from source .ts files; keep module resolution aligned.
          module: "Node16",
          moduleResolution: "Node16",
          target: "ES2022",
          esModuleInterop: true,
          skipLibCheck: true,
        },
        diagnostics: { ignoreCodes: [151002] },
      },
    ],
  },
  testMatch: ["**/tests/**/*.test.ts"],
};
