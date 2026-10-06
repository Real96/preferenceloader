#import <UIKit/UIKit.h>

// The parts of PLRootList.m that are not specific to one generation of the Settings root list.
//
// There are two generations, and they share nothing but these helpers:
//
//   iOS 18-26  SettingsApp.PrimarySettingsListModel        -> PLRootList.m
//   iOS 27+    SettingsApp.SettingsSidebarListState        -> PLSidebarList.m
//
// Reading the Preferences directory, turning an entry into a pane through libprefs and keeping
// one pane per tweak are identical either way, so they live in PLRootList.m and are declared
// here rather than duplicated. Everything that touches a model type stays in its own file.

#ifdef __cplusplus
extern "C" {
#endif

// Where PreferenceLoader keeps its entries, and the directory one entry's plist was read from
// (the Preferences directory itself, or a subdirectory for a localized entry).
NSString *PLPreferencesDirectory(void);
NSString *PLEntrySourceDirectory(NSDictionary *record);

// The installed tweaks' labels, sorted, read once per launch. The records behind them are keyed
// by label: @{ @"entry": <the entry dict>, @"name": <plist name>, @"source": <directory> }.
NSArray<NSString *> *PLTweakTitles(void);
NSMutableDictionary<NSString *, NSDictionary *> *PLEntriesByTitle(void);

// The image an entry names, looked up the way PreferenceLoader looks it up, or nil.
UIImage *PLIconForEntry(NSDictionary *record);

// Marks a row as ours. Written into the identifier enum's String payload, and read back to turn
// a tap into a pane.
NSString *PLIdentityKeyForTitle(NSString *title);

// The pane for a tweak, built through libprefs on first use and kept for the life of the
// process. It is titled and marked so the navigation hooks recognise it. nil when the entry
// cannot be resolved.
UIViewController *PLRootListPaneForTitle(NSString *title);

#ifdef __cplusplus
}
#endif
