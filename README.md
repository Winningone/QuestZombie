# QuestZombie (Wrath of the Lich King 3.3.5)

QuestZombie is a quest automation addon for **World of Warcraft: Wrath of the Lich King (3.3.5)**.
It automatically accepts quests, skips unnecessary dialogue, completes quests, and intelligently selects quest rewards based on class, specialization, and currently equipped gear.

The addon is designed to reduce repetitive quest interactions while still allowing players to override automation when desired.

---

## Current Development Status

QuestZombie is currently in **active development (beta)**.

---

## Features

**Quest Automation**

* Automatically accepts quests
* Skips NPC greeting menus
* Automatically completes quests
* Optional escort quest confirmation
* Works during raid groups if enabled
* Adds ability to use number keys to select quest rewards with 1 being the upper left reward and progressing left to right then top to bottom.
* An intelligent reward selection system (In Development)

**Smart Reward Selection**

The intelligent reward system is implemented for the following classes:

* Hunter
* Rogue
* Warrior
* Paladin

Additional classes will be added in future updates.

Because reward scoring logic must account for many gear combinations and special cases, **player testing is important**. Feedback from real gameplay helps refine the selection system.

The addon evaluates quest rewards based on:

* Player class
* Player specialization
* Equipped gear comparison
* Weapon role logic (main-hand / off-hand / two-hand)
* Armor type preferences
* Stat weighting by role
* Vendor value fallback

Instead of simply picking the highest item level, the addon attempts to choose the **largest real upgrade for the player's build**.

**Dual-Slot Gear Comparison**

For items such as:

* rings
* trinkets
* one-handed weapons

QuestZombie compares the reward against **both equipped slots** and selects the reward that produces the largest upgrade.

**Weapon Role Logic**

For classes that depend on weapon roles (such as Rogues and Warriors), the addon considers:

* main-hand vs off-hand weapon speed
* weapon pairing
* two-handed vs dual-wield configurations
* specialization preferences

---

## Default Behavior

When the addon is first installed, the following settings are active:

**General Automation**

* Addon enabled
* Quests automatically accepted
* NPC greeting menus skipped
* Quests automatically completed
* Escort auto-confirm **disabled**
* Automation allowed in raids

**Reward System**

* Smart reward selection enabled
* Reward mode: **automatic**
* Class detection: **automatic**
* Spec detection: **automatic**

If the addon cannot determine a clear upgrade, it will fall back to **manual reward selection**.

---

## Slash Commands

```
/qz status
```

Displays the current configuration.

```
/qz toggle
```

Enable or disable the addon.

```
/qz gui
```

Open the configuration window.

```
/qz mode auto
/qz mode manual
/qz mode vendor
```

Reward selection modes:

* **auto** – intelligent reward selection
* **manual** – player selects reward manually
* **vendor** – chooses highest vendor value

```
/qz class auto|hunter|rogue|warrior|paladin
```

Overrides class detection.

```
/qz spec auto|bm|mm|sv|ass|combat|sub|arms|fury|prot|holy|ret
```

Overrides specialization detection.

---

## Debug Mode (Important for Testing)

Players who want to help test the reward system can enable debug mode.

```
/qz debugreward on
```

When enabled, the addon prints the **full reward scoring breakdown** for each quest reward.

Example debug information includes:

* selected reward
* upgrade score
* equipped item score
* stat weighting
* armor preference
* weapon role bonuses

If the addon selects the wrong reward, take a screenshot of the debug output shown in chat when reporting the issue and include the following information:
Class, Spec, Name of Quest, Which reward should have been chosen.

Disable debug mode with:

```
/qz debugreward off
```

---

## Feedback Requested

If you encounter incorrect reward choices, please include the following information:

* Character class
* Specialization
* Character level
* Quest name
* Rewards offered
* Debug output from `/qz debugreward`

This information allows scoring logic to be adjusted accurately.

---

## Planned Features

Future development goals include:

* Intelligent reward logic for remaining classes
* Additional stat weighting refinements
* Expanded role detection
* GUI improvements
* configurable reward priority profiles

---

## Compatibility

QuestZombie is designed for:

**World of Warcraft – Wrath of the Lich King (3.3.5)**

---

## License

This addon may be freely distributed and modified for personal use. Attribution to the original project is appreciated.

---

## Installation

1. Download the addon folder.
2. Place it in: World of Warcraft/Interface/AddOns/

```

