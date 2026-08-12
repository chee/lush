import { describe, expect, it } from "vitest";
import {
  DEFAULT_ENDPOINT,
  embedSubductionEndpoints,
  subductionEndpoints,
} from "./config";

describe("embedSubductionEndpoints", () => {
  it("uses only the core's internal server", () => {
    expect(
      embedSubductionEndpoints({
        coreWsPort: 43219,
        publicEndpoint: "wss://elsewhere.example",
        localWsPorts: [43219, 9999],
      }),
    ).toEqual(["ws://127.0.0.1:43219"]);
  });

  it("is empty until the port is known", () => {
    expect(embedSubductionEndpoints({})).toEqual([]);
    expect(embedSubductionEndpoints({ localWsPorts: [9999] })).toEqual([]);
  });
});

describe("subductionEndpoints", () => {
  it("keeps the public endpoint plus local ports", () => {
    expect(subductionEndpoints({ localWsPorts: [1234] })).toEqual([
      DEFAULT_ENDPOINT,
      "ws://127.0.0.1:1234",
    ]);
  });
});
