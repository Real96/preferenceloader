#import <UIKit/UIKit.h>

// Puts the PreferenceLoader entries into the Settings root list on iOS 27 and later.
//
// iOS 27 rebuilt the root list a second time. Where iOS 18-26 drive it from
// SettingsApp.PrimarySettingsListModel (see PLRootList.m), iOS 27 drives it from
// SettingsApp.SettingsSidebarListState, whose rows are generic SettingsHost types shared with
// the rest of the Settings UI:
//
//   iOS 18-26                                 iOS 27+
//   PrimarySettingsListModel                  SettingsSidebarListState
//     _cachedDataModel                          _cachedSnapshot
//   PrimarySettingsListSectionModel           SettingsHost.SettingsListSectionModel<S, I>
//   PrimarySettingsListItemModel              SettingsHost.SettingsListItemModel<I>
//   PrimarySettingsListItemViewType.link      SettingsHost.SettingsListItemViewType.label
//   Icon.IconType.image(UIImage)              SettingsHost.SettingsIconRepresentation.IconType
//
// Three of those differences matter beyond the renaming:
//
//   * There is no `link` case any more. A row that opens a page is a `label`, and whether it
//     navigates is decided by the list's selection delegate rather than by the row's shape.
//   * There is no `image(UIImage)` icon case any more, so a UIImage cannot be handed to the
//     model at all. The only case that names a file is `namedImage(name:bundle:)`, which is
//     resolved through CoreUI and therefore only finds images in an asset catalog -- which a
//     PreferenceLoader icon, a loose PNG beside its plist, never is. The rows are given a marker
//     name instead and SwiftUI's Image(_:bundle:) is intercepted to serve the real artwork.
//   * Navigation is value-based: tapping a row hands SwiftUI the row's identifier and SwiftUI
//     builds a destination for it. An identifier Settings does not know builds an empty page, and
//     nothing observable from UIKit says which row was tapped. The tap is recognised from the
//     highlight the cell takes on touch-down instead, which carries its index path.

#ifdef __cplusplus
extern "C" {
#endif

// Whether this firmware has the iOS 27 root list. Gates everything else, and is what Tweak.xm
// asks instead of checking a version number.
BOOL PLSidebarListAvailable(void);

// Installs the runloop observer that appends the tweak section to each snapshot Settings
// publishes, and the icon interception. Safe to call before the list exists: the observer
// resolves the model on each turn and does nothing until it is there.
void PLSidebarListInstallInjector(void);

// Records the row that is being pressed. Called from the UICollectionViewCell hook in Tweak.xm;
// the cell is resolved to an index path against its own collection view.
void PLSidebarListNoteHighlightedCell(id cell);

// The pane for the row that was just tapped, or nil when the tap was not one of ours.
//
// Read at the moment Settings pushes: a tap is the only thing that both highlights one of our
// cells and pushes a controller, so the pairing is unambiguous. The record is consumed, so a
// second push cannot reuse it.
UIViewController *PLSidebarListPaneForTappedRow(void);

#ifdef __cplusplus
}
#endif
