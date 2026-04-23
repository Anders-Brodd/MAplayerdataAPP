// Replace these sample dictionaries with your real in-game IDs and enum values.
export const idDictionaries = {
  SlopeId: {
    "1": "Bunny Hill",
    "2": "Blue Ridge",
    "3": "Summit Black"
  },
  LiftId: {
    "101": "Base Quad",
    "102": "Summit Express"
  },
  ItemId: {
    "5001": "Rental Skis",
    "5002": "Hot Cocoa"
  },
  EventType: {
    SessionStart: "Session Start",
    SessionEnd: "Session End",
    Purchase: "Purchase",
    ResearchUnlock: "Research Unlock"
  }
};

export const valueMappers = {
  // Example: convert weather numeric state to human-readable label.
  WeatherState: (value) => {
    const map = {
      0: "Clear",
      1: "Cloudy",
      2: "Snow",
      3: "Storm"
    };
    return map[value] || value;
  }
};
