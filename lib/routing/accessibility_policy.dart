enum PathwayType {
  walkway,
  ramp,
  stairs,
  elevator,
  entrance,
  accessibleEntrance,
}

class AccessibilityPolicy {
  const AccessibilityPolicy();

  bool canUsePath({
    required PathwayType type,
    required bool accessibleRouting,
  }) {
    if (!accessibleRouting) {
      return true;
    }

    switch (type) {
      case PathwayType.stairs:
        return false;

      case PathwayType.walkway:
      case PathwayType.ramp:
      case PathwayType.elevator:
      case PathwayType.accessibleEntrance:
        return true;

      case PathwayType.entrance:
        return false;
    }
  }
}
