#import "PLSidebarList.h"
#import "PLRootList.h"
#import "PLRootListInternal.h"
#import "PLSwiftMeta.h"
#import "PLHeap.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>

#define DEBUG_TAG "PreferenceLoader"
#import "debug.h"

#if DEBUG
#define PLSidebarLog(...) PLRootListNote([NSString stringWithFormat:__VA_ARGS__])
#else
#define PLSidebarLog(...) ((void)0)
#endif

// --- the types the list is made of ----------------------------------------------------------
//
// Mangled names minus the "$s" prefix. The row types are generic over the two identifier enums,
// so their names carry those enums as arguments; writing them out is what lets
// swift_getTypeByMangledNameInContext hand back the specialisation the model actually holds.
// A rename in a future release fails to resolve rather than resolving to something else.

static const char *const kPLItemIDType    = "11SettingsApp33SettingsSidebarListItemIdentifierO";
static const char *const kPLSectionIDType = "11SettingsApp36SettingsSidebarListSectionIdentifierO";
static const char *const kPLSectionType   =
    "12SettingsHost24SettingsListSectionModelVy11SettingsApp36SettingsSidebarListSectionIdentifierO"
    "11SettingsApp33SettingsSidebarListItemIdentifierOG";
static const char *const kPLItemType      =
    "12SettingsHost21SettingsListItemModelVy11SettingsApp33SettingsSidebarListItemIdentifierOG";
static const char *const kPLViewTypeType  = "12SettingsHost24SettingsListItemViewTypeO";
static const char *const kPLLabelType     = "12SettingsHost22SettingsListLabelModelV";
static const char *const kPLIconRepType   = "12SettingsHost26SettingsIconRepresentationV";
static const char *const kPLIconTypeType  = "12SettingsHost26SettingsIconRepresentationV8IconTypeO";

static NSString *const kPLListStateClass = @"SettingsApp.SettingsSidebarListState";

// The row shape a plain entry is built from, and the icon case that names a file.
static const char *const kPLLabelCase      = "label";
static const char *const kPLNamedImageCase = "namedImage";

// PrimarySettingsListItemIdentifier.connectedHeadphone(identifier:) survived the rewrite as
// SettingsSidebarListItemIdentifier.connectedHeadphone, and is still the only case carrying a
// bare String. Giving every injected row that case with a distinct string is what lets SwiftUI
// tell the rows apart without spending one of the enum's finite empty cases per tweak.
static const char *const kPLIdentifierCarrierCase = "connectedHeadphone";

// The section's identity. Preferred rather than guaranteed: while headphones are connected
// Settings has a section of its own under this case, and a duplicate identity is drawn once.
static const char *const kPLSectionIdentityCase = "connectedHeadphones";

// The count field inside a native Swift array buffer, after its object header.
enum { kPLArrayCountOffset = 16 };

typedef struct {
    const void *itemIDMeta;
    const void *sectionIDMeta;
    const void *sectionMeta;
    const void *itemMeta;
    const void *viewTypeMeta;
    const void *labelMeta;
    const void *iconRepMeta;
    const void *iconTypeMeta;

    size_t sectionStride;
    size_t itemStride;

    int32_t sectionID;
    int32_t sectionItems;
    int32_t itemID;
    int32_t itemViewType;
    int32_t labelIcon;
    int32_t labelText;
    int32_t repIconType;

    const void *snapshot;   // the section array field inside _cachedSnapshot
    NSInteger sectionCount;
    __unsafe_unretained id state;
} PLSidebarContext;

static BOOL PLSidebarResolve(PLSidebarContext *ctx) {
    memset(ctx, 0, sizeof(*ctx));

    ctx->itemIDMeta    = PLSwiftTypeByMangledName(kPLItemIDType);
    ctx->sectionIDMeta = PLSwiftTypeByMangledName(kPLSectionIDType);
    ctx->sectionMeta   = PLSwiftTypeByMangledName(kPLSectionType);
    ctx->itemMeta      = PLSwiftTypeByMangledName(kPLItemType);
    ctx->viewTypeMeta  = PLSwiftTypeByMangledName(kPLViewTypeType);
    ctx->labelMeta     = PLSwiftTypeByMangledName(kPLLabelType);
    ctx->iconRepMeta   = PLSwiftTypeByMangledName(kPLIconRepType);
    ctx->iconTypeMeta  = PLSwiftTypeByMangledName(kPLIconTypeType);
    if (!ctx->sectionMeta || !ctx->itemMeta || !ctx->viewTypeMeta || !ctx->labelMeta) return NO;

    ctx->sectionStride = PLSwiftTypeStride(ctx->sectionMeta);
    ctx->itemStride    = PLSwiftTypeStride(ctx->itemMeta);
    if (ctx->sectionStride == 0 || ctx->itemStride == 0) return NO;

    ctx->sectionID    = PLSwiftStructOffsetOfField(ctx->sectionMeta, "id");
    ctx->sectionItems = PLSwiftStructOffsetOfField(ctx->sectionMeta, "items");
    ctx->itemID       = PLSwiftStructOffsetOfField(ctx->itemMeta, "id");
    ctx->itemViewType = PLSwiftStructOffsetOfField(ctx->itemMeta, "type");
    ctx->labelIcon    = PLSwiftStructOffsetOfField(ctx->labelMeta, "icon");
    ctx->labelText    = PLSwiftStructOffsetOfField(ctx->labelMeta, "text");
    ctx->repIconType  = ctx->iconRepMeta ? PLSwiftStructOffsetOfField(ctx->iconRepMeta, "iconType") : -1;
    if (ctx->sectionItems < 0 || ctx->itemViewType < 0 || ctx->labelText < 0) return NO;

    Class listState = objc_getClass(kPLListStateClass.UTF8String);
    if (!listState) return NO;

    // Walking the malloc zones is the only way to reach the state object (see PLHeap.h), and far
    // too expensive to repeat, so the instance is remembered. It lives as long as the scene does,
    // and a stale one simply fails to resolve a snapshot.
    static __unsafe_unretained id sState = nil;
    if (!sState) {
        __unsafe_unretained id instances[4];
        if (PLHeapFindInstances(listState, instances, 4) == 0) return NO;
        sState = instances[0];
    }

    Ivar cached = class_getInstanceVariable(listState, "_cachedSnapshot");
    if (!cached) return NO;

    // The snapshot's first stored property is the section array, and the Optional wrapping it
    // rides in that array pointer's spare bits, so a nil snapshot reads as a null buffer.
    ctx->state = sState;
    ctx->snapshot = (__bridge void *)sState + ivar_getOffset(cached);
    ctx->sectionCount = PLSwiftArrayCount(ctx->snapshot);
    return ctx->sectionCount > 0;
}

BOOL PLSidebarListAvailable(void) {
    return objc_getClass(kPLListStateClass.UTF8String) != Nil;
}

// --- icons ------------------------------------------------------------------------------------
//
// The model can only name an image, and only resolves names through CoreUI's asset catalogs, so
// a loose PNG beside an entry's plist cannot be referenced at all. Each row is therefore given a
// name no catalog will ever hold -- the same "PLTweak:<title>" string the row's identity uses --
// and SwiftUI's Image(_:bundle:) is intercepted: a name in this table is answered with the real
// artwork, everything else goes to Apple's implementation untouched.

static NSMutableDictionary<NSString *, UIImage *> *PLSidebarIcons(void) {
    static NSMutableDictionary *icons;
    static dispatch_once_t once;
    // Owned, not autoreleased: this file is compiled without ARC.
    dispatch_once(&once, ^{ icons = [[NSMutableDictionary alloc] init]; });
    return icons;
}

// SwiftUI.Image is one word, so both initialisers return a plain pointer.
typedef void *(*PLImageNamedFn)(uintptr_t nameLow, uintptr_t nameHigh, void *bundle);
typedef void *(*PLImageUIImageFn)(void *uiImage);
typedef void (*PLSwiftReleaseFn)(void *object);

static PLImageNamedFn PLImageNamedOriginal = NULL;
static PLImageUIImageFn PLImageWithUIImage = NULL;
static PLSwiftReleaseFn PLSwiftRelease = NULL;

static void *PLImageNamedReplacement(uintptr_t nameLow, uintptr_t nameHigh, void *bundle) {
    // Apple's implementation runs either way. It is what consumes the String argument, and its
    // result is the only safe thing to hand back when the name is not one of ours.
    void *original = PLImageNamedOriginal(nameLow, nameHigh, bundle);

    UIImage *image = nil;
    if (PLSidebarIcons().count) {
        uintptr_t words[2] = { nameLow, nameHigh };
        char *name = PLSwiftStringCopyUTF8(words);
        if (name) {
            image = PLSidebarIcons()[@(name)];
            free(name);
        }
    }
    if (!image || !PLImageWithUIImage) return original;

    if (PLSwiftRelease) PLSwiftRelease(original);
    // Retained on every call on purpose. The images live in the table for the life of the
    // process, so a reference that is never dropped costs nothing but a counter -- whereas
    // guessing wrong about whether the initialiser consumes its argument would over-release a
    // live object.
    return PLImageWithUIImage((void *)[image retain]);
}

static void PLSidebarInstallIconHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Image.init(_: String, bundle: NSBundle?) and Image.init(uiImage: UIImage). Both are
        // public API and exported, so they are reached by name rather than by offset.
        void *named = dlsym(RTLD_DEFAULT, "$s7SwiftUI5ImageV_6bundleACSS_So8NSBundleCSgtcfC");
        PLImageWithUIImage = (PLImageUIImageFn)dlsym(RTLD_DEFAULT, "$s7SwiftUI5ImageV02uiC0ACSo7UIImageC_tcfC");
        PLSwiftRelease = (PLSwiftReleaseFn)dlsym(RTLD_DEFAULT, "swift_release");
        if (!named || !PLImageWithUIImage) {
            PLSidebarLog(@"[icon] SwiftUI Image initialisers not found; rows will be drawn without artwork");
            return;
        }
        MSHookFunction(named, (void *)&PLImageNamedReplacement, (void **)&PLImageNamedOriginal);
        PLSidebarLog(@"[icon] interception installed");
    });
}

// --- building a row ---------------------------------------------------------------------------

// Gives an item its own identity. The template's identifier is an empty case, so it holds no
// references and can be overwritten before the carrier tag is injected.
static void PLSidebarSetItemIdentity(PLSidebarContext *ctx, void *item, NSString *key) {
    uint32_t tag = PLSwiftEnumTagNamed(ctx->itemIDMeta, kPLIdentifierCarrierCase);
    size_t size = PLSwiftTypeSize(ctx->itemIDMeta);
    if (tag == UINT32_MAX || size == 0 || ctx->itemID < 0) return;
    void *identifier = (uint8_t *)item + ctx->itemID;
    memset(identifier, 0, size);
    PLSwiftStringInitialize(key.UTF8String, identifier);
    PLSwiftEnumInject(identifier, tag, ctx->itemIDMeta);
}

// Whether a row is a plain label, which is what the injected rows are copied from.
static BOOL PLSidebarItemIsLabel(PLSidebarContext *ctx, const void *item) {
    const void *viewType = (const uint8_t *)item + ctx->itemViewType;
    const char *caseName = PLSwiftEnumCaseName(ctx->viewTypeMeta,
                                               PLSwiftEnumTag(viewType, ctx->viewTypeMeta));
    return caseName && strcmp(caseName, kPLLabelCase) == 0;
}

// Rewrites a copied label row to carry the tweak's title and icon. NO when the row was not a
// label after all, which is what makes the caller give up rather than write into a shape it does
// not understand.
static BOOL PLSidebarSetItemAppearance(PLSidebarContext *ctx, void *item, NSString *title,
                                       NSString *iconKey, BOOL hasIcon) {
    void *viewType = (uint8_t *)item + ctx->itemViewType;
    uint32_t tag = PLSwiftEnumTag(viewType, ctx->viewTypeMeta);
    const char *caseName = PLSwiftEnumCaseName(ctx->viewTypeMeta, tag);
    if (!caseName || strcmp(caseName, kPLLabelCase) != 0) return NO;

    PLSwiftEnumProject(viewType, ctx->viewTypeMeta);
    PLSwiftStringAssign((uint8_t *)viewType + ctx->labelText, title.UTF8String);

    // The icon is a SettingsIconRepresentation whose first field is the case telling it what to
    // draw. namedImage carries (name: String, bundle: NSBundle) -- the String at the front of the
    // payload, the bundle one word past it. The old value owns references and is destroyed through
    // its own witness before being overwritten.
    uint32_t imageTag = PLSwiftEnumTagNamed(ctx->iconTypeMeta, kPLNamedImageCase);
    // An entry with no artwork is given the empty case rather than left alone: the row was copied
    // from one of Apple's, and what it inherits otherwise is that row's icon.
    uint32_t noneTag = PLSwiftEnumTagNamed(ctx->iconTypeMeta, "none");
    uint32_t wanted = hasIcon ? imageTag : noneTag;
    size_t iconSize = ctx->iconTypeMeta ? PLSwiftTypeSize(ctx->iconTypeMeta) : 0;
    if (ctx->labelIcon >= 0 && ctx->repIconType >= 0 && iconSize > 0 && wanted != UINT32_MAX) {
        void *field = (uint8_t *)viewType + ctx->labelIcon + ctx->repIconType;
        PLSwiftValueDestroy(field, ctx->iconTypeMeta);
        memset(field, 0, iconSize);
        if (hasIcon) {
            PLSwiftStringInitialize(iconKey.UTF8String, field);
            // Any bundle will do: the name is answered from the tweak's own table before Apple's
            // lookup ever uses it. The main bundle is the one guaranteed to be alive.
            *(void **)((uint8_t *)field + 16) = (void *)[NSBundle.mainBundle retain];
        }
        PLSwiftEnumInject(field, wanted, ctx->iconTypeMeta);
    }

    PLSwiftEnumInject(viewType, tag, ctx->viewTypeMeta);
    return YES;
}

// --- placing the section ------------------------------------------------------------------

static const char *PLSidebarSectionIdentityName(PLSidebarContext *ctx, const void *section) {
    if (!section || ctx->sectionID < 0 || !ctx->sectionIDMeta) return NULL;
    const void *identifier = (const uint8_t *)section + ctx->sectionID;
    return PLSwiftEnumCaseName(ctx->sectionIDMeta, PLSwiftEnumTag(identifier, ctx->sectionIDMeta));
}

// Sections Settings adds for a connected accessory, matched by substring because the case is
// named per accessory class and there is more than one of them.
static BOOL PLSidebarIsAccessorySection(const char *caseName) {
    return caseName != NULL &&
           (strcasestr(caseName, "headphone") != NULL || strcasestr(caseName, "accessor") != NULL);
}

static BOOL PLSidebarSectionTagInUse(PLSidebarContext *ctx, uint32_t tag) {
    if (tag == UINT32_MAX) return YES;
    for (NSInteger i = 0; i < ctx->sectionCount; i++) {
        const void *section = PLSwiftArrayElement(ctx->snapshot, i, ctx->sectionStride);
        if (!section) continue;
        const void *identifier = (const uint8_t *)section + ctx->sectionID;
        if (PLSwiftEnumTag(identifier, ctx->sectionIDMeta) == tag) return YES;
    }
    return NO;
}

// An empty case of the identifier enum that no section in this snapshot is using. The preferred
// one first; otherwise from the last case down, since a case Apple appended late is the least
// likely to name a section that is in the list.
static uint32_t PLSidebarSectionIdentityTag(PLSidebarContext *ctx) {
    if (ctx->sectionID < 0 || !ctx->sectionIDMeta) return UINT32_MAX;

    uint32_t preferred = PLSwiftEnumTagNamed(ctx->sectionIDMeta, kPLSectionIdentityCase);
    if (preferred != UINT32_MAX && !PLSidebarSectionTagInUse(ctx, preferred)) return preferred;

    for (uint32_t tag = PLSwiftEnumCaseCount(ctx->sectionIDMeta); tag-- > 0;) {
        if (PLSwiftEnumCaseHasPayload(ctx->sectionIDMeta, tag)) continue;
        if (PLSidebarSectionTagInUse(ctx, tag)) continue;
        return tag;
    }
    return UINT32_MAX;
}

// The section the injected one is copied from, and the row inside it the rows are copied from:
// the lowest section whose identity is an empty case and whose first row is a plain label.
static const void *PLSidebarTemplateSection(PLSidebarContext *ctx, const void **itemOut) {
    for (NSInteger i = ctx->sectionCount; i-- > 0;) {
        const void *section = PLSwiftArrayElement(ctx->snapshot, i, ctx->sectionStride);
        if (!section) continue;
        if (PLSidebarIsAccessorySection(PLSidebarSectionIdentityName(ctx, section))) continue;
        // Overwriting the copy's identity counts on there being nothing to release.
        if (ctx->sectionID >= 0 && ctx->sectionIDMeta &&
            PLSwiftEnumCaseHasPayload(ctx->sectionIDMeta,
                                      PLSwiftEnumTag((const uint8_t *)section + ctx->sectionID,
                                                     ctx->sectionIDMeta))) continue;

        const void *items = (const uint8_t *)section + ctx->sectionItems;
        const void *item = PLSwiftArrayElement(items, 0, ctx->itemStride);
        if (!item || !PLSidebarItemIsLabel(ctx, item)) continue;

        if (itemOut) *itemOut = item;
        return section;
    }
    return NULL;
}

// Above the accessory sections at the foot of the list, at the very end when there are none.
static NSInteger PLSidebarInsertIndex(PLSidebarContext *ctx) {
    NSInteger index = ctx->sectionCount;
    while (index > 0) {
        const void *section = PLSwiftArrayElement(ctx->snapshot, index - 1, ctx->sectionStride);
        if (!section || !PLSidebarIsAccessorySection(PLSidebarSectionIdentityName(ctx, section))) break;
        index--;
    }
    return index;
}

// Which section of the live list the injected rows ended up in, and the titles in the order they
// were written. The tap hook turns an index path into a tweak through these.
static NSInteger gPLInjectedSection = -1;
static NSArray<NSString *> *gPLInjectedTitles = nil;

static void PLSidebarInjectSection(void) {
    PLSidebarContext ctx;
    if (!PLSidebarResolve(&ctx)) return;

    NSArray<NSString *> *titles = PLTweakTitles();
    if (titles.count == 0) return;

    // Dropped up front rather than overwritten at the end: everything below can give up part way,
    // and an index left over from the previous snapshot would make the tap hook attribute one of
    // Apple's rows to a tweak.
    gPLInjectedSection = -1;

    const void *templateItem = NULL;
    const void *templateSection = PLSidebarTemplateSection(&ctx, &templateItem);
    if (!templateSection || !templateItem) {
        PLSidebarLog(@"[inject] no label section to copy");
        return;
    }
    const void *templateItems = (const uint8_t *)templateSection + ctx.sectionItems;

    void *items = PLSwiftArrayAllocate(templateItems, (NSInteger)titles.count, ctx.itemStride, 7);
    if (!items) { PLSidebarLog(@"[inject] item array allocation failed"); return; }

    uint8_t *itemBase = (uint8_t *)items + PLSwiftArrayElementOffset();
    for (NSUInteger i = 0; i < titles.count; i++) {
        void *item = itemBase + i * ctx.itemStride;
        PLSwiftValueInitializeWithCopy(item, templateItem, ctx.itemMeta);

        NSString *identity = PLIdentityKeyForTitle(titles[i]);
        PLSidebarSetItemIdentity(&ctx, item, identity);

        // The icon is registered under the same string the row is identified by, so the
        // interception can find it without a second table keyed on anything else.
        UIImage *image = PLIconForEntry(PLEntriesByTitle()[titles[i]]);
        if (image) PLSidebarIcons()[identity] = image;

        if (!PLSidebarSetItemAppearance(&ctx, item, titles[i], identity, image != nil)) {
            PLSidebarLog(@"[inject] row %lu is not a label; aborting", (unsigned long)i);
            return;
        }
    }

    // Both read the list as Apple left it, so they are settled before the rebuild below moves any
    // section out from under the context's count and indices.
    NSInteger index = PLSidebarInsertIndex(&ctx);
    uint32_t sectionTag = PLSidebarSectionIdentityTag(&ctx);

    NSInteger capacity = PLSwiftArrayCapacity(ctx.snapshot);
    uintptr_t storage = *(const uintptr_t *)ctx.snapshot;

    // Written into the array's spare capacity when the section belongs at the end and there is
    // room, into a larger buffer otherwise. Replacing the buffer is safe only because this runs
    // before the evaluation that follows Apple's rebuild: SwiftUI has not read the model yet and
    // picks up whichever buffer it finds.
    if (capacity <= ctx.sectionCount || index < ctx.sectionCount) {
        void *grown = PLSwiftArrayAllocate(ctx.snapshot, ctx.sectionCount + 1, ctx.sectionStride, 7);
        if (!grown) { PLSidebarLog(@"[inject] could not grow the section array"); return; }
        uint8_t *base = (uint8_t *)grown + PLSwiftArrayElementOffset();
        for (NSInteger i = 0; i < ctx.sectionCount; i++) {
            PLSwiftValueInitializeWithCopy(base + (i < index ? i : i + 1) * ctx.sectionStride,
                                           PLSwiftArrayElement(ctx.snapshot, i, ctx.sectionStride),
                                           ctx.sectionMeta);
        }
        // The old buffer keeps one retain nobody drops. Releasing it would assert that nothing
        // else holds the array, which is not a claim this code can make about Apple's model.
        *(void **)ctx.snapshot = grown;
        storage = (uintptr_t)grown;
    }

    void *slot = (void *)(storage + PLSwiftArrayElementOffset() + (size_t)index * ctx.sectionStride);
    PLSwiftValueInitializeWithCopy(slot, templateSection, ctx.sectionMeta);
    if (ctx.sectionID >= 0 && sectionTag != UINT32_MAX) {
        void *identifier = (uint8_t *)slot + ctx.sectionID;
        memset(identifier, 0, PLSwiftTypeSize(ctx.sectionIDMeta));
        PLSwiftEnumInject(identifier, sectionTag, ctx.sectionIDMeta);
    }
    // The copy retained the template's item array; overwriting the field drops that reference
    // without releasing it, for the same reason as above.
    *(void **)((uint8_t *)slot + ctx.sectionItems) = items;

    // Raising the count is the last step, so the slot is complete before the list can see it.
    *(NSInteger *)(storage + kPLArrayCountOffset) = ctx.sectionCount + 1;

    [gPLInjectedTitles release];
    gPLInjectedTitles = [titles copy];
    gPLInjectedSection = index;
    PLSidebarLog(@"[inject] section %td holds %lu row(s)", index, (unsigned long)titles.count);
}

// --- injecting into Apple's own rebuild --------------------------------------------------

// The snapshot last injected into: its buffer address and the section count left behind. The
// address alone is not an identity -- Apple frees a snapshot buffer and later allocates another
// at the same address -- so the pair is carried and anything else is treated as a rebuild.
static const void *gPLInjectedInto = NULL;
static NSInteger gPLInjectedCount = -1;

static void PLSidebarInjectOnNewSnapshot(CFRunLoopObserverRef observer, CFRunLoopActivity activity,
                                         void *info) {
    PLSidebarContext ctx;
    if (!PLSidebarResolve(&ctx)) return;

    // Keeps almost every runloop turn to a couple of loads.
    const void *storage = *(const void *const *)ctx.snapshot;
    if (!storage || (storage == gPLInjectedInto && ctx.sectionCount == gPLInjectedCount)) return;

    PLSidebarInjectSection();

    // Read back afterwards rather than remembered from before: when the array has to be grown,
    // the injection replaces this very pointer.
    gPLInjectedInto = *(const void *const *)ctx.snapshot;
    gPLInjectedCount = PLSwiftArrayCount(ctx.snapshot);
}

void PLSidebarListInstallInjector(void) {
    static CFRunLoopObserverRef observer;
    if (observer) return;

    PLSidebarInstallIconHook();

    // Ahead of CoreAnimation, whose commit observer sits at order 2000000 and is where SwiftUI
    // evaluates: a section added to a new snapshot before that evaluation needs no redraw trigger
    // of its own.
    observer = CFRunLoopObserverCreate(kCFAllocatorDefault,
                                       kCFRunLoopBeforeTimers | kCFRunLoopBeforeWaiting,
                                       true, -2000000, PLSidebarInjectOnNewSnapshot, NULL);
    if (!observer) return;
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    PLSidebarLog(@"[injector] installed");
}

// --- turning a tap into a pane ----------------------------------------------------------------
//
// Nothing observable from UIKit says which row SwiftUI is navigating to: the identifier lives
// only inside the NavigationStack's own path, the selection state is left untouched, and the
// controller that gets pushed is the same empty host whatever row was tapped. What is observable
// is the highlight the cell takes on touch-down, and a cell knows its index path.

static NSInteger gPLTappedSection = -1;
static NSInteger gPLTappedItem = -1;
static CFTimeInterval gPLTappedAt = 0;

// Long enough to cover the press and the push that follows it, short enough that a highlight
// left behind by something else cannot still be standing when an unrelated push arrives.
static const CFTimeInterval kPLTapWindow = 5.0;

void PLSidebarListNoteHighlightedCell(id cell) {
    if (gPLInjectedSection < 0) return;

    UIView *view = cell;
    UICollectionView *collection = nil;
    for (int depth = 0; view && depth < 20; depth++) {
        if ([view isKindOfClass:UICollectionView.class]) { collection = (UICollectionView *)view; break; }
        view = view.superview;
    }
    if (!collection) return;

    NSIndexPath *path = [collection indexPathForCell:(UICollectionViewCell *)cell];
    if (!path) return;

    gPLTappedSection = path.section;
    gPLTappedItem = path.item;
    gPLTappedAt = CACurrentMediaTime();
}

UIViewController *PLSidebarListPaneForTappedRow(void) {
    if (gPLTappedSection < 0 || gPLTappedSection != gPLInjectedSection) return nil;
    if (CACurrentMediaTime() - gPLTappedAt > kPLTapWindow) return nil;
    if (gPLTappedItem < 0 || (NSUInteger)gPLTappedItem >= gPLInjectedTitles.count) return nil;

    // Consumed: the pane belongs to this push and must not be substituted into the next one.
    NSString *title = gPLInjectedTitles[gPLTappedItem];
    gPLTappedSection = -1;

    PLSidebarLog(@"[open] %@ was tapped", title);
    return PLRootListPaneForTitle(title);
}
