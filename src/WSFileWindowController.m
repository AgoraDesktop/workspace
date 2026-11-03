/*
 * WSFileWindowController.m — the file window's shell, assembled from the platform's parts.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * THE WINDOW IS FOUR STRIPS AND ONE TREE, and every one of them reads the same model:
 *
 *   toolbar       Back, Forward and the three-way view switcher (only Icon enabled)
 *   path bar      the current folder, one component per path element
 *   sidebar       PLACES and DEVICES, in an NSOutlineView inside an NSSplitView
 *   content       the icon view, the list view or the column view
 *   status bar    "N items", from the model's own count
 *
 * **THE RESPONDER CHAIN IS HOW THE MENUS REACH THE WINDOW.** The window's `-nextResponder` is this controller, so
 * the View and Go rows (which have no target) resolve here when a file window is key. The File menu's New Window
 * row is the application's, and is targeted explicitly by `WSMainMenu`.
 */
#import "WSFileWindowController.h"

#import "WSColumnView.h"
#import "WSConflictSheet.h"
#import "WSFileOperations.h"
#import "WSIconView.h"
#import "WSListView.h"
#import "WSHistory.h"
#import "WSItemDrag.h"
#import "WSItemIcons.h"
#import "WSItemModel.h"
#import "WSPlaces.h"
#import "WSProgressWindow.h"
#import "WSDirectoryWatcher.h"
#import "WSTrash.h"
#import "WSHairlineView.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSLayoutAnchor.h>
#import <AppKit/NSLayoutConstraint.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSPathComponentCell.h>
#import <AppKit/NSPathControl.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSSearchField.h>
#import <AppKit/NSSegmentedControl.h>
#import <AppKit/NSSplitView.h>
#import <AppKit/NSWorkspace.h>
#import <AppKit/NSTableColumn.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSTextFieldCell.h>
#import <AppKit/NSToolbarItem.h>
#import <AppKit/NSView.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSIndexSet.h>
#import <Foundation/NSNotification.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSUndoManager.h>
#import <Foundation/NSUserDefaults.h>
#import <Foundation/NSValue.h>

#import <LaunchServices/LSOpen.h>
#import <CoreFoundation/CFString.h>
#import <CoreFoundation/CFURL.h>

#include <math.h>
#include <stdio.h>

#define WS_PATH_BAR_HEIGHT 24.0
#define WS_STATUS_BAR_HEIGHT 22.0
#define WS_SIDEBAR_WIDTH 220.0

static NSString * const WSFileWindowToolbarIdentifier = @"WorkspaceFileWindowToolbar";
static NSString * const WSBackItemIdentifier = @"WorkspaceBack";
static NSString * const WSForwardItemIdentifier = @"WorkspaceForward";
static NSString * const WSViewSwitcherItemIdentifier = @"WorkspaceViewSwitcher";
/* **THE SEARCH FIELD IS ITS OWN ITEM AND SITS TO THE SWITCHER'S RIGHT**, which is where a Mac's file window keeps it: the
 * view switch says HOW the folder is drawn and the field says WHICH of it, so the two read left to right as one
 * sentence — and the field is last because it grows. */
static NSString * const WSSearchFieldItemIdentifier = @"WorkspaceSearchField";
/* **THE ONE PREFERENCE A TOOLBAR HAS: WHETHER ITS ITEMS SAY THEIR WORDS.** A file window's band is a Back, a Forward
 * and a mode switch, so the words are useful the first time and clutter every time after — which is why the View menu
 * offers to put them away and the answer is remembered. The key lives here rather than in a preferences class because
 * the toolbar is what reads it. */
static NSString * const WSToolbarLabelsKey = @"WSShowToolbarLabels";
/* **WHICH VIEW A FILE WINDOW OPENS IN, WHICH IS A PREFERENCE RATHER THAN A PER-WINDOW CHOICE.** A person browses their
 * folders in one of the three ways almost always, and choosing it again in every new window is the tax that preference
 * exists to remove. The View menu and the toolbar switch still change the WINDOW they are in — that is the per-window
 * half, and it is not written here: opening a window with List because the last one was switched to List would make the
 * default meaningless. */
static NSString * const WSDefaultViewModeKey = @"WSDefaultViewMode";
/* **THE PLACES PANE'S WIDTH, AS THE PERSON DRAGGED IT.** `WS_SIDEBAR_WIDTH` is what a window nobody has dragged shows; a
 * drag writes the pane's own width here and every later window opens at it. A width outside the range a window can
 * usefully have is refused rather than stored, so a stray value cannot make the list unreadable. */
static NSString * const WSSidebarWidthKey = @"WSSidebarWidth";
#define WS_SIDEBAR_MIN_WIDTH 140.0
#define WS_SIDEBAR_MAX_WIDTH 400.0

/* ============================================================================================ *
 * THE SIDEBAR'S CELL — a text field cell that draws the place's picture beside its title.      *
 * ============================================================================================ */

/* **THE STANDARD TEXT-FIELD CELL DRAWS TEXT AND NOT THE IMAGE IT IS GIVEN**, so the sidebar's places would be a
 * list of words. This is the smallest subclass that honours `-setImage:`: draw the picture in a sixteen-point box,
 * inset the text by its width, and let the inherited drawing do the rest. Section rows have no image and are
 * unaffected. */
@interface WSPlaceCell : NSTextFieldCell
@end

@implementation WSPlaceCell
- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
	NSImage *image = [self image];

	if (image != nil) {
		NSRect box = NSMakeRect(cellFrame.origin.x + 2.0,
					cellFrame.origin.y + floor((cellFrame.size.height - 16.0) / 2.0),
					16.0, 16.0);

		[image drawInRect:box];
		cellFrame.origin.x += 20.0;
		cellFrame.size.width -= 20.0;
	}
	[super drawInteriorWithFrame:cellFrame inView:controlView];
}
@end


/* **A NEW DOCUMENT ENTERS AT ITS ORIGIN.** The clip view keeps its bounds origin when the document changes, so a
 * scrolled icon grid would hand that offset to the column browser (or the list) and the new view would draw as if it
 * were scrolled to the same place. Resetting is the one line that makes a view swap show the new view's beginning. */
static void fn_resetContentScroll(NSScrollView *scroll)
{
	NSClipView *clip = (NSClipView *)[scroll contentView];
	NSPoint origin = NSZeroPoint;

	if (clip == nil) {
		return;
	}
	[clip scrollToPoint:origin];
	[scroll reflectScrolledClipView:clip];
}

/* ============================================================================================ *
 * THE CONTENT VIEW — THREE STRIPS PLACED BY CONSTRAINTS.                                        *
 *                                                                                                *
 * **THE STRIPS USED TO BE FRAMES THE CONTENT VIEW COMPUTED ITSELF, AND A WINDOW RESIZE DID NOT   *
 * MOVE THEM.** The arithmetic lived in `-resizeSubviewsWithOldSize:`, and this tier's           *
 * `NSView -setFrame:` does NOT call that hook — a window resize sets the content view's FRAME.   *
 * The three strips therefore kept the geometry they were born with. Auto Layout is the door      *
 * that runs on a frame set (`-setFrame:` requests a pass), so the layout is constraints and      *
 * there is no resize hook left to forget.                                                       *
 *                                                                                                *
 * The content view itself is UNMANAGED: it is the root, `NSWindow` sets its frame, and it is    *
 * the ancestor that owns the constraints. The path bar, the split view and the status bar are    *
 * the managed views.                                                                            *
 * ============================================================================================ */

@interface WSFileWindowController (WSFileWindowLayout)
- (void)installStripConstraints;
- (void)refreshContentSizes;
@end

/* ============================================================================================ *
 * THE CONTROLLER.                                                                               *
 * ============================================================================================ */

@implementation WSFileWindowController

- (instancetype)initWithDirectory:(NSString *)directory
{
	NSWindow *window;
	NSView *content;

	window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 900.0, 560.0)
					     styleMask:(NSTitledWindowMask | NSClosableWindowMask |
							NSMiniaturizableWindowMask | NSResizableWindowMask)
					       backing:NSBackingStoreBuffered defer:NO];
	self = [super initWithWindow:window];
	[window release];
	if (self == nil) {
		return nil;
	}
	[window setReleasedWhenClosed:NO];
	[window setMinSize:NSMakeSize(520.0, 320.0)];
	[window setDelegate:self];
	[window setNextResponder:self];

	_directory = [directory copy];
	_model = [[WSItemModel alloc] initWithDirectory:_directory];
	_history = [[WSHistory alloc] initWithURL:[NSURL fileURLWithPath:_directory]];
	_placeSections = [[WSPlaces sections] retain];
	_viewMode = 0;
	_undoManager = [[NSUndoManager alloc] init];
	_trash = [[WSTrash alloc] init];
	_fileOperations = [[WSFileOperations alloc] initWithUndoManager:_undoManager trash:_trash];
	{
		__block WSFileWindowController *weakSelf = self;

		[_fileOperations setProgressHandler:^(NSUInteger completed, NSUInteger total, NSString *path) {
			[weakSelf progress:completed total:total path:path];
		}];
		[_fileOperations setConflictHandler:^WSFileConflictResolution(NSString *destination) {
			return [WSConflictSheet askWithDestination:destination parentWindow:[weakSelf window]];
		}];
	}

	content = [[NSView alloc] initWithFrame:NSZeroRect];
	[window setContentView:content];
	[content release];

	_isTrashDirectory = [self fn_isTrashDirectory:_directory];
	[self fn_watchDirectory];
	[self buildPathBar];
	[self buildContentAndSidebar];
	[self buildStatusBar];
	[self installStripConstraints];

	[self buildToolbar];
	[self refresh];
	/* **AND THEN THE PREFERENCE, THROUGH THE SAME DOOR THE SWITCHER USES.** Setting the field above only says which view
	 * is wanted; building it is `-setViewMode:`'s job, and a window whose field said Column while its content was still
	 * the icon grid would be a preference that changed a word and nothing else: MEASURED, exactly that. A caller that wants
	 * another mode for this one window (`--list-view`, a test) sets it after this and wins. */
	[self setViewMode:[WSFileWindowController cg_defaultViewMode]];
	return self;
}

- (void)dealloc
{
	[_watcher invalidate];
	[_watcher release];
	[_stripConstraints release];
	[_directory release];
	[_model release];
	[_history release];
	[_placeSections release];
	[_progressWindow release];
	[_fileOperations release];
	[_trash release];
	[_undoManager release];
	[super dealloc];
}

/* ---- THE PIECES ----------------------------------------------------------------------------- */

- (void)buildPathBar
{
	_pathBar = [[NSPathControl alloc] initWithFrame:NSMakeRect(0.0, 0.0, 900.0, WS_PATH_BAR_HEIGHT)];
	[_pathBar setPathStyle:NSPathStyleNavigationBar];
	[_pathBar setTarget:self];
	[_pathBar setAction:@selector(pathBarClicked:)];
}

- (void)buildContentAndSidebar
{
	NSTableColumn *column;
	NSWindow *window = [self window];

	_split = [[NSSplitView alloc] initWithFrame:NSMakeRect(0.0, WS_PATH_BAR_HEIGHT, 900.0,
							     560.0 - WS_PATH_BAR_HEIGHT - WS_STATUS_BAR_HEIGHT)];
	[_split setVertical:YES];
	/* **THE SIDEBAR'S DIVIDER IS THE SPLIT VIEW'S GUTTER**, the same eighteen-point pane splitter the browser's
	 * columns use: a person can drag it, and the three rings say so. */
	[_split setDividerStyle:NSSplitViewDividerStylePaneSplitter];

	{
		CGFloat remembered = [WSFileWindowController cg_sidebarWidth];

		_sidebarScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 0.0, remembered, 500.0)];
	}
	[_sidebarScroll setHasVerticalScroller:YES];
	[_sidebarScroll setAutohidesScrollers:YES];
	[_sidebarScroll setBorderType:NSNoBorder];
	[_sidebarScroll setDrawsBackground:YES];
	_sidebar = [[NSOutlineView alloc] initWithFrame:[[_sidebarScroll contentView] bounds]];
	column = [[NSTableColumn alloc] initWithIdentifier:@"place"];
	[column setWidth:[WSFileWindowController cg_sidebarWidth] - 20.0];
	{
		WSPlaceCell *cell = [[WSPlaceCell alloc] init];

		[column setDataCell:cell];
		[cell release];
	}
	[_sidebar addTableColumn:column];
	[_sidebar setOutlineTableColumn:column];
	[column release];
	[_sidebar setHeaderView:nil];
	[_sidebar setRowHeight:22.0];
	[_sidebar setIndentationPerLevel:12.0];
	[_sidebar setSelectionHighlightStyle:NSTableViewSelectionHighlightStyleSourceList];
	[_sidebar setAllowsEmptySelection:YES];
	[_sidebar setAllowsMultipleSelection:NO];
	[_sidebar setBackgroundColor:[NSColor controlBackgroundColor]];
	[_sidebar setDataSource:self];
	[_sidebar setDelegate:self];
	[_sidebar reloadData];
	{
		NSUInteger i;

		for (i = 0; i < [_placeSections count]; i++) {
			[_sidebar expandItem:[_placeSections objectAtIndex:i]];
		}
	}
	[_sidebarScroll setDocumentView:_sidebar];

	_contentScroll = [[NSScrollView alloc] initWithFrame:
		NSMakeRect([WSFileWindowController cg_sidebarWidth], 0.0,
			   900.0 - [WSFileWindowController cg_sidebarWidth], 500.0)];
	[_contentScroll setHasVerticalScroller:YES];
	/* **A BAR THE DOCUMENT DOES NOT NEED STEPS ASIDE, the same rule as the sidebar's and the browser's columns.
	 * Without autohide a configured scroller is always a subview, so the icon grid wore a full-height bar in a
	 * folder whose rows already fit. */
	[_contentScroll setAutohidesScrollers:YES];
	[_contentScroll setBorderType:NSNoBorder];
	[_contentScroll setDrawsBackground:YES];
	_iconView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0,
								     900.0 - [WSFileWindowController cg_sidebarWidth], 500.0)
						    model:_model];
	[_iconView setDelegate:(id <WSIconViewDelegate>)self];
	[_iconView setFileOperations:_fileOperations];
	[_contentScroll setDocumentView:_iconView];

	[_split setDelegate:self];
	[_split addSubview:_sidebarScroll];
	[_split addSubview:_contentScroll];
	[_split adjustSubviews];
	[_split setPosition:[WSFileWindowController cg_sidebarWidth] ofDividerAtIndex:0];

	if (!_isTrashDirectory) {
		[[window contentView] addSubview:_pathBar];
	}
	[[window contentView] addSubview:_split];
}

- (void)buildStatusBar
{
	_status = [[NSTextField alloc] initWithFrame:NSMakeRect(0.0, 0.0, 900.0, WS_STATUS_BAR_HEIGHT)];
	[_status setEditable:NO];
	[_status setSelectable:NO];
	[_status setBordered:NO];
	[_status setBezeled:NO];
	[_status setDrawsBackground:NO];
	[_status setTextColor:[NSColor darkGrayColor]];
	[_status setStringValue:@""];
	[[[self window] contentView] addSubview:_status];

	/* **AND THE RULE BETWEEN THE PANE AND THAT STRIP.** The status bar is a label, not a control: it has no border to
	 * give, so the split view's panes ended at the window's face with nothing between them — the one meeting in this
	 * window without a line, now that a column's title strip and each side of the splitter have one. */
	_statusRule = [[WSHairlineView alloc] initWithFrame:NSMakeRect(0.0, WS_STATUS_BAR_HEIGHT, 900.0, 1.0)];
	[[[self window] contentView] addSubview:_statusRule];
}

/* ---- THE CONTENT VIEW'S CONSTRAINTS --------------------------------------------------------- */

/* **THREE CONSTRAINTS PER STRIP, AND THE SPLIT VIEW IS THE ONE THAT FLEXES.** The path bar is pinned to the top
 * with its height, the status bar to the bottom with its height, and the split view fills the band between them and
 * the full width. The window's content view is the common ancestor, so every constraint is owned by it; the strips
 * stop translating their autoresizing masks, because a frame written by the window would otherwise be a second,
 * contradictory equation. */
- (void)installStripConstraints
{
	NSView *content = [[self window] contentView];

	[_pathBar setTranslatesAutoresizingMaskIntoConstraints:NO];
	[_split setTranslatesAutoresizingMaskIntoConstraints:NO];
	[_status setTranslatesAutoresizingMaskIntoConstraints:NO];
	[_statusRule setTranslatesAutoresizingMaskIntoConstraints:NO];

	NSMutableArray *constraints = [NSMutableArray array];

	if (!_isTrashDirectory) {
		[constraints addObjectsFromArray:[NSArray arrayWithObjects:
			[[_pathBar leadingAnchor] constraintEqualToAnchor:[content leadingAnchor]],
			[[_pathBar trailingAnchor] constraintEqualToAnchor:[content trailingAnchor]],
			[[_pathBar topAnchor] constraintEqualToAnchor:[content topAnchor]],
			[[_pathBar heightAnchor] constraintEqualToConstant:WS_PATH_BAR_HEIGHT],
			nil]];
	}
	[constraints addObjectsFromArray:[NSArray arrayWithObjects:
		[[_split leadingAnchor] constraintEqualToAnchor:[content leadingAnchor]],
		[[_split trailingAnchor] constraintEqualToAnchor:[content trailingAnchor]],
		_isTrashDirectory
			? [[_split topAnchor] constraintEqualToAnchor:[content topAnchor]]
			: [[_split topAnchor] constraintEqualToAnchor:[_pathBar bottomAnchor]],
		[[_split bottomAnchor] constraintEqualToAnchor:[_statusRule topAnchor]],
		[[_statusRule heightAnchor] constraintEqualToConstant:1.0],
		[[_statusRule leadingAnchor] constraintEqualToAnchor:[content leadingAnchor]],
		[[_statusRule trailingAnchor] constraintEqualToAnchor:[content trailingAnchor]],
		[[_statusRule bottomAnchor] constraintEqualToAnchor:[_status topAnchor]],

		[[_status leadingAnchor] constraintEqualToAnchor:[content leadingAnchor]],
		[[_status trailingAnchor] constraintEqualToAnchor:[content trailingAnchor]],
		[[_status bottomAnchor] constraintEqualToAnchor:[content bottomAnchor]],
		[[_status heightAnchor] constraintEqualToConstant:WS_STATUS_BAR_HEIGHT],
		nil]];
	[NSLayoutConstraint activateConstraints:constraints];
	[_stripConstraints release];
	_stripConstraints = [constraints copy];
}

/* **THE DOCUMENT VIEW'S SIZE IS STILL THE SHELL'S, BECAUSE A SCROLL VIEW'S DOCUMENT IS NOT A STRIP.** The split
 * view resized the content pane; the icon grid, the list and the browser inside it each answer a different
 * question about how much room they need, so the delegate hook below asks after every pane resize and this does
 * the arithmetic once. It runs AFTER the split view has written the pane frames — `-adjustSubviews` posts its
 * notification at the end — which is why it reads the new clip bounds rather than the old ones. */
- (void)refreshContentSizes
{
	[self refreshIconFrame];
	if (_viewMode == 1 && _listView != nil) {
		[_listView tile];
	}
	if (_viewMode == 2 && _columnView != nil) {
		[_columnView setFrameSize:[[_contentScroll contentView] bounds].size];
	}
}

- (void)buildToolbar
{
	_toolbar = [[NSToolbar alloc] initWithIdentifier:WSFileWindowToolbarIdentifier];
	[_toolbar setDelegate:self];
	[_toolbar setDisplayMode:[WSFileWindowController cg_toolbarLabelsVisible]
				  ? NSToolbarDisplayModeIconAndLabel : NSToolbarDisplayModeIconOnly];
	[[self window] setToolbar:_toolbar];
}

/* ---- THE MODEL, THE PATH BAR, THE STATUS BAR AND THE TITLE ---------------------------------- */

- (NSString *)directory { return _directory; }
- (NSInteger)itemCount { return (_model != nil) ? (NSInteger)[[_model items] count] : 0; }

- (void)refreshIconFrame
{
	CGFloat width = [[_contentScroll contentView] bounds].size.width;
	CGFloat height;

	if (width <= 0.0) {
		width = [_contentScroll frame].size.width;
	}
	height = [_iconView contentHeightForWidth:width];
	if (height < [[_contentScroll contentView] bounds].size.height) {
		height = [[_contentScroll contentView] bounds].size.height;
	}
	[_iconView setFrameSize:NSMakeSize(width, height)];
}

/* **WHICH FOLDERS ARE TRASHES, BY THE RULE THIS TIER ALREADY MOVES BY**: the home Trash for the home volume, and a
 * `.Trash-<uid>` on any other. Both are named that way by `WSTrash`'s own rule (`WSTrash.h`), so the test is the name
 * and not a second table of directories — a volume mounted tomorrow has a Trash the moment it has one of those. */
/* **IS THIS WINDOW SHOWING THE TRASH? ASK ON EVERY NAVIGATION, NOT ONCE.** The answer decides the title and whether the
 * path bar exists at all, so it is a fact about the window's CURRENT directory: a window opened on `.Trash` and then
 * sent Home must show `kyle` and its breadcrumb again. The path bar is not merely hidden — it is not in the layout —
 * so the constraints are taken down and put back rather than a hidden flag flipped. */
- (void)fn_applyTrashLayout
{
	BOOL wasTrash = _isTrashDirectory;

	_isTrashDirectory = [self fn_isTrashDirectory:_directory];
	if (_isTrashDirectory == wasTrash) {
		return;
	}
	if (_stripConstraints != nil) {
		[NSLayoutConstraint deactivateConstraints:_stripConstraints];
		[_stripConstraints release];
		_stripConstraints = nil;
	}
	if (_isTrashDirectory) {
		[_pathBar removeFromSuperview];
	} else {
		[[[self window] contentView] addSubview:_pathBar];
	}
	[self installStripConstraints];
}

- (BOOL)fn_isTrashDirectory:(NSString *)directory
{
	NSString *name = [directory lastPathComponent];

	if ([name isEqual:@".Trash"]) {
		return YES;
	}
	return [name hasPrefix:@".Trash-"];
}

/* **THE WINDOW WATCHES WHAT IT SHOWS: ITS FOLDER, AND THE FOLDERS IT HAS EXPANDED.** Not the folder recursively — a
 * change under a folder nobody opened cannot change a row that is drawn, and asking the kernel about a home directory
 * was measured as a freeze. The list view answers which rows are open (`-cg_expandedPaths`), and each is one watch, so
 * an expanded subtree is live while it is open and stops being watched when it closes.
 *
 * The watcher is replaced when the window navigates, because a stream for the directory somebody left is an ear on
 * nothing; a changed SET of paths keeps the watcher and rebuilds its stream (`-setPaths:`). */
- (NSArray *)fn_watchedPaths
{
	NSMutableArray *paths = [NSMutableArray array];

	if (_directory != nil) {
		[paths addObject:_directory];
	}
	/* **THE LIST'S OPEN SUBTREES AND THE BROWSER'S OPEN COLUMNS.** A grid shows one folder and adds nothing; a tree keeps
	 * its expanded rows open, and a browser keeps one column per level — both are places on the glass, so both are
	 * watched. Without the browser's half a change in a column several levels down was invisible until something else
	 * refreshed the window: MEASURED as "column view is slow to notice changes in the filesystem". */
	if (_viewMode == 1 && _listView != nil) {
		NSArray *expanded = [_listView cg_expandedPaths];
		NSUInteger i;

		for (i = 0; expanded != nil && i < [expanded count]; i++) {
			NSString *path = [expanded objectAtIndex:i];

			if (path != nil && ![paths containsObject:path]) {
				[paths addObject:path];
			}
		}
	} else if (_viewMode == 2 && _columnView != nil) {
		NSArray *open = [_columnView cg_visibleDirectories];
		NSUInteger i;

		/* THE SAME FOLDER IS ONE WATCH: column zero lists the window's own folder, which is already in the list. */
		for (i = 0; open != nil && i < [open count]; i++) {
			NSString *path = [open objectAtIndex:i];

			if (path != nil && ![paths containsObject:path]) {
				[paths addObject:path];
			}
		}
	}
	return paths;
}

- (void)fn_watchDirectory
{
	[_watcher invalidate];
	[_watcher release];
	_watcher = [[WSDirectoryWatcher alloc] initWithPaths:[self fn_watchedPaths]
						      target:self
						      action:@selector(fn_directoryDidChange:)];
}

/* **A CHANGE ON THE DISK IS A REFRESH, NOT A RELOAD OF THE WORLD.** Everything the window shows is read from the
 * model, so the same `-refresh` a command uses is the right answer here: it re-reads the directory, keeps the selection
 * and the view mode, and leaves the columns standing (see `WSColumnView -reloadData`). An operation of this window's
 * own also ends in a refresh, so its two halves can arrive together — reading a directory twice is cheap and being out
 * of date is not. */
- (void)fn_directoryDidChange:(WSDirectoryWatcher *)watcher
{
	(void)watcher;
	[self refresh];
}

- (WSDirectoryWatcher *)cg_watcher { return _watcher; }

/* **WHAT THE BREADCRUMB AND THE TITLE SAY THE WINDOW IS SHOWING.** In Icon and List mode that is the folder the window
 * holds. **IN COLUMN MODE IT IS THE FOLDER THE RIGHTMOST COLUMN LISTS**: a browser shows a chain of folders at once, and
 * the one a person has walked into is the one on the right — the path bar reading the leftmost column meant the crumbs
 * stopped at the window's own folder however deep the columns went, which is the one thing a breadcrumb is for. The
 * window's own folder is still `_directory`: the model, the watchers, Back and Forward and every command are about it, and
 * this changes what is SAID rather than where the window is. */
- (NSString *)fn_displayDirectory
{
	NSArray *open;

	if (_viewMode != 2 || _columnView == nil) {
		return _directory;
	}
	open = [_columnView cg_visibleDirectories];
	if (open == nil || [open count] == 0) {
		return _directory;
	}
	return [open lastObject];
}

/* THE STRIP AND THE TITLE, WHICH ARE ONE ANSWER IN TWO PLACES: the places that change what the columns show call this
 * instead of re-reading the whole folder. */
- (void)fn_updatePathBarAndTitle
{
	NSString *shown = [self fn_displayDirectory];
	NSString *title = (shown != nil) ? [shown lastPathComponent] : nil;

	if (_isTrashDirectory) {
		[[self window] setTitle:@"Trash"];
		return;
	}
	if (!_isTrashDirectory) {
		[_pathBar setURL:[NSURL fileURLWithPath:shown]];
	}
	if (title == nil || [title length] == 0) {
		title = shown;
	}
	[[self window] setTitle:title];
}

- (void)refresh
{
	NSInteger count;
	NSString *title;

	/* **EVERY REFRESH READS THE FOLDER, AND THAT IS THE POINT OF IT.** `WSItemModel` reads its directory once and caches
	 * the answer, so a refresh that only re-laid the views out showed the OLD contents: a folder made by this window's
	 * own New Folder did not appear until a person navigated away and back, and nothing another application did appeared
	 * at all. The model is re-read here, which is what every caller of this method actually means. */
	[_model reload];
	count = [self itemCount];
	title = [[self fn_displayDirectory] lastPathComponent];

	/* **AND A READ-AGAIN FOLDER IS NOT A DIFFERENT FOLDER.** `-setModel:` starts the grid over (no selection), so it is
	 * only for a navigation; a refresh lays the same model out again and keeps what a person had chosen. */
	if ([_iconView model] != _model) {
		[_iconView setModel:_model];
	} else {
		[_iconView reloadData];
	}
	if (_listView != nil) {
		if ([_listView model] != _model) {
			[_listView setModel:_model];
		} else {
			[_listView reloadData];
			[_listView tile];
		}
	}
	if (_columnView != nil) {
		if ([_columnView model] != _model) {
			[_columnView setModel:_model];
		} else {
			[_columnView reloadData];
		}
		[_columnView setFrameSize:[[_contentScroll contentView] bounds].size];
	}
	/* **THE TRASH IS A PLACE, NOT A PATH.** `~/.Trash` is where it lives, and a breadcrumb ending in `.Trash` under
	 * somebody's home directory says nothing true about it: a person is looking at the Trash and can empty it, put things
	 * back or open them, and where the directory sits is the file manager's business. So the title is `Trash` and the
	 * path bar is not there at all — the same way the Mac's Trash window shows no path. Everywhere else is unchanged. */
	/* **THE TRASH HAS NO PATH BAR AT ALL.** A breadcrumb ending in `.Trash` under somebody's home directory says nothing
	 * true about the place: a person is looking at the Trash, where things can be put back, opened or emptied, and where
	 * the directory sits is the file manager's business. So the strip is not there — the same way the Mac's Trash window
	 * shows no path — and everywhere else is unchanged. */
	/* **THE TRASH SHOWS NO PATH, BECAUSE ITS WINDOW HAS NO BAR.** The strip is not built for one (see
	 * `installStripConstraints`), so there is nothing here to empty. */
	if (!_isTrashDirectory) {
		[_pathBar setURL:[NSURL fileURLWithPath:[self fn_displayDirectory]]];
	}
	[_status setStringValue:[NSString stringWithFormat:@"%ld %@", (long)count,
				  (count == 1) ? @"item" : @"items"]];
	if (title == nil || [title length] == 0) {
		title = [self fn_displayDirectory];
	}
	if (_isTrashDirectory) {
		title = @"Trash";
	}
	[[self window] setTitle:title];
	[self refreshIconFrame];
	/* **AND THE WATCHES FOLLOW THE ROWS.** Expanding a folder calls this through `-listViewDidChangeModel:`, so the
	 * subtree is watched from the moment it is open; collapsing it drops the path. A refresh that changes nothing does
	 * no work — `-setPaths:` compares. */
	[_watcher setPaths:[self fn_watchedPaths]];
	[self syncSidebarSelection];
	[_toolbar validateVisibleItems];
}

- (void)syncSidebarSelection
{
	NSString *standard = [_directory stringByStandardizingPath];
	NSUInteger s;
	WSPlace *match = nil;

	for (s = 0; s < [_placeSections count] && match == nil; s++) {
		WSPlaceSection *section = [_placeSections objectAtIndex:s];
		NSUInteger p;

		for (p = 0; p < [[section places] count]; p++) {
			WSPlace *place = [[section places] objectAtIndex:p];

			if ([[[place path] stringByStandardizingPath] isEqual:standard]) {
				match = place;
				break;
			}
		}
	}
	_syncingSidebar = YES;
	if (match != nil) {
		NSInteger row = [_sidebar rowForItem:match];

		if (row >= 0) {
			[_sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
				   byExtendingSelection:NO];
		}
	} else {
		[_sidebar deselectAll:nil];
	}
	_syncingSidebar = NO;
}

/* ---- NAVIGATION ----------------------------------------------------------------------------- */

- (void)showDirectory:(NSString *)directory push:(BOOL)push
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *standard = [directory stringByStandardizingPath];
	BOOL isDirectory = NO;

	if (standard == nil
	    || ![manager fileExistsAtPath:standard isDirectory:&isDirectory]
	    || !isDirectory) {
		return;
	}
	if (push) {
		[_history pushURL:[NSURL fileURLWithPath:standard]];
	}
	if ([standard isEqual:_directory] && push) {
		[_model reload];
		[self refresh];
		return;
	}
	/* **A NEW FOLDER IS A NEW QUESTION, SO THE FIELD LETS GO OF THE OLD ONE.** The model below is made fresh and
	 * unfiltered; a field still reading `b.t` over a folder it has not filtered would be a search box that lies about
	 * what the window is showing. */
	[_searchField setStringValue:@""];
	[_directory release];
	_directory = [standard copy];
	[_model release];
	_model = [[WSItemModel alloc] initWithDirectory:_directory];
	/* **A WINDOW CAN ENTER OR LEAVE THE TRASH, AND THE STRIP IS ABOUT WHERE IT IS.** The path bar and the title were
	 * decided once, when the window was made: a window opened ON the trash kept its `.Trash` title and no path bar after
	 * navigating to Home. Both are re-decided here, with the constraints rebuilt because the path bar is part of the
	 * layout rather than a hidden view. */
	[self fn_applyTrashLayout];
	[self fn_watchDirectory];
	[self refresh];
}

- (void)navigateToDirectory:(NSString *)directory
{
	[self showDirectory:directory push:YES];
}

- (BOOL)canGoBack { return [_history canGoBack]; }
- (BOOL)canGoForward { return [_history canGoForward]; }

- (void)goBack:(id)sender
{
	(void)sender;
	if (![_history goBack]) {
		return;
	}
	[self showDirectory:[[_history currentURL] path] push:NO];
}

- (void)goForward:(id)sender
{
	(void)sender;
	if (![_history goForward]) {
		return;
	}
	[self showDirectory:[[_history currentURL] path] push:NO];
}

- (void)goToEnclosingFolder:(id)sender
{
	(void)sender;
	[self navigateToDirectory:[_directory stringByDeletingLastPathComponent]];
}

- (void)goHome:(id)sender
{
	(void)sender;
	[self navigateToDirectory:NSHomeDirectory()];
}

- (void)goToDesktop:(id)sender
{
	(void)sender;
	[self navigateToDirectory:[WSPlaces desktopDirectory]];
}

- (void)goToApplications:(id)sender
{
	(void)sender;
	[self navigateToDirectory:[WSPlaces applicationsDirectory]];
}

- (void)goToComputer:(id)sender
{
	(void)sender;
	[self navigateToDirectory:@"/"];
}

/* ---- THE VIEW SWITCHER ---------------------------------------------------------------------- */

- (NSInteger)viewMode { return _viewMode; }

- (void)setViewMode:(NSInteger)mode
{
	if (mode < 0 || mode > 2 || mode == _viewMode) {
		if (_viewSwitcher != nil) {
			[_viewSwitcher setSelectedSegment:mode];
		}
		return;
	}
	_viewMode = mode;
	if (_viewSwitcher != nil) {
		[_viewSwitcher setSelectedSegment:mode];
	}
	if (mode == 0) {
		[_contentScroll setDocumentView:_iconView];
		fn_resetContentScroll(_contentScroll);
		[_iconView setModel:_model];
		[self refreshIconFrame];
	} else if (mode == 1) {
		if (_listView == nil) {
			_listView = [[WSListView alloc] initWithFrame:[[_contentScroll contentView] bounds]
							       model:_model];
			[_listView setListDelegate:(id <WSListViewDelegate>)self];
			[_listView setFileOperations:_fileOperations];
		} else {
			[_listView setModel:_model];
		}
		[_contentScroll setDocumentView:_listView];
		fn_resetContentScroll(_contentScroll);
		[_listView reloadData];
		[_listView tile];
	} else {
		if (_columnView == nil) {
			_columnView = [[WSColumnView alloc] initWithFrame:[[_contentScroll contentView] bounds]
								   model:_model];
			[_columnView setViewDelegate:(id <WSColumnViewDelegate>)self];
		} else {
			[_columnView setModel:_model];
		}
		/* **THE BROWSER MOVES THROUGH THE WINDOW'S OPERATIONS, SO A DROP IT PERFORMS IS UNDOABLE.** It has no undo
		 * manager of its own, and the Edit menu that takes the move back is the window's. */
		[_columnView setFileOperations:_fileOperations];
		[_contentScroll setDocumentView:_columnView];
		fn_resetContentScroll(_contentScroll);
		[_columnView setFrameSize:[[_contentScroll contentView] bounds].size];
	}
	[_watcher setPaths:[self fn_watchedPaths]];
}

- (void)cg_useIconView:(id)sender
{
	(void)sender;
	[self setViewMode:0];
}

- (void)cg_useListView:(id)sender
{
	(void)sender;
	[self setViewMode:1];
}

- (void)cg_useColumnView:(id)sender
{
	(void)sender;
	[self setViewMode:2];
}

- (void)viewSwitcherChanged:(id)sender
{
	NSInteger segment = [_viewSwitcher selectedSegment];

	(void)sender;
	if (segment < 0 || segment > 2) {
		[_viewSwitcher setSelectedSegment:_viewMode];
		return;
	}
	[self setViewMode:segment];
}

/* ---- THE PATH BAR AND THE ICON VIEW --------------------------------------------------------- */

- (void)pathBarClicked:(id)sender
{
	NSPathComponentCell *cell = [_pathBar clickedPathComponentCell];
	NSURL *url = (cell != nil) ? [cell URL] : nil;

	(void)sender;
	if (url != nil && [url path] != nil) {
		[self navigateToDirectory:[url path]];
	}
}

- (void)iconView:(WSIconView *)view openItem:(WSItem *)item
{
	(void)view;
	[self openItem:item];
}

- (void)listView:(WSListView *)view openItem:(WSItem *)item
{
	(void)view;
	[self openItem:item];
}

- (void)listViewDidChangeModel:(WSListView *)view
{
	(void)view;
	[self refresh];
}

- (void)columnView:(WSColumnView *)view openItem:(WSItem *)item
{
	(void)view;
	[self openItem:item];
}

- (void)columnViewDidChangeVisibleDirectories:(WSColumnView *)view
{
	(void)view;
	[_watcher setPaths:[self fn_watchedPaths]];
	/* **AND THE CRUMBS FOLLOW THE COLUMNS.** Walking into a folder in a browser changes what the window is showing without
	 * changing the folder it holds, so the strip is updated here rather than by a refresh — the model has not changed. */
	[self fn_updatePathBarAndTitle];
}

- (void)columnViewDidChangeModel:(WSColumnView *)view
{
	(void)view;
	[self refresh];
}

/* **A DOCUMENT OPENS THROUGH THE WORKSPACE'S OWN APPKIT DOOR, NOT THROUGH THE SEAM DIRECTLY.** `NSWorkspace` is this
 * stack's face over Launch Services — `WORKSPACE-PLAN.md` puts it in the AppKit rather than here — so the file manager
 * asks it and the policy (which applications are registered, what a type resolves to, what a refusal looks like) stays
 * in the one place that owns it. MEASURED: this method used to build a CFURL and call `LSOpenCFURLRef` itself, which
 * meant the file window had a second copy of the launch decision and no way to see the AppKit's answer.
 *
 * **AND A FOLDER IS NAVIGATED WHILE A PACKAGE IS OPENED.** `isDirectory` alone cannot tell them apart — an `.app` bundle
 * is a directory — so a bundle used to be entered and its `Contents` shown, when what a person double-clicking an
 * application asked for was for it to RUN. A package is the item that is one thing rather than a place, and opening it
 * is `-openFile:`, which launches an application bundle and refuses a package that is not one. */
- (void)openItem:(WSItem *)item
{
	if ([item isBrowsable]) {
		[self navigateToDirectory:[item path]];
	} else {
		(void)[[NSWorkspace sharedWorkspace] openFile:[item path]];
	}
}

/* A RENAME OR A DROP CHANGED THE MODEL: the count may be the same, but the status bar and both views are the
 * model's, and this is the moment to re-read them. */
- (void)iconViewDidChangeModel:(WSIconView *)view
{
	(void)view;
	[self refresh];
}

/* **AND A COMMAND THE GRID PERFORMED ENDS WHERE THIS WINDOW'S OWN COMMANDS END.** The operation manager the icon view was
 * handed is this window's (`-setFileOperations:` at load), so the progress plate its handler opened is this window's to
 * close — the grid cannot close it, and asking only for a refresh left that plate on the glass. */
- (void)iconViewDidFinishOperation:(WSIconView *)view
{
	(void)view;
	[self finishOperation];
}

/* ---- THE TOOLBAR ---------------------------------------------------------------------------- */

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)identifier
     willBeInsertedIntoToolbar:(BOOL)flag
{
	NSToolbarItem *item;

	(void)toolbar;
	(void)flag;
	if ([identifier isEqualToString:WSBackItemIdentifier]) {
		item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
		[item setLabel:@"Back"];
		[item setPaletteLabel:@"Back"];
		/* **THE ARROW IS THE PLATFORM'S, NOT THIS APPLICATION'S.** `NSImageNameGoLeftTemplate` is a TEMPLATE, so
		 * the toolbar draws it in its own ink — dimmed with the label when there is nowhere to go back to — which
		 * is the whole reason the glyph is a stencil and not a picture of a grey arrow. */
		[item setImage:[NSImage imageNamed:NSImageNameGoLeftTemplate]];
		[item setTarget:self];
		[item setAction:@selector(goBack:)];
		[item setEnabled:[self canGoBack]];
		return item;
	}
	if ([identifier isEqualToString:WSForwardItemIdentifier]) {
		item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
		[item setLabel:@"Forward"];
		[item setPaletteLabel:@"Forward"];
		[item setImage:[NSImage imageNamed:NSImageNameGoRightTemplate]];
		[item setTarget:self];
		[item setAction:@selector(goForward:)];
		[item setEnabled:[self canGoForward]];
		return item;
	}
	if ([identifier isEqualToString:WSViewSwitcherItemIdentifier]) {
		NSInteger i;
		/* **THREE PICTURES, NOT THREE WORDS — THE SAME PAIR OF PICTURES FOR A PAIR OF PANES THAT THE DETAIL SWITCH USES.**
		 * A file window's three views are a MODE, and a mode switch is what a segmented control is for: `Icon`, `List`
		 * and `Column` were three words in a band of verbs, which read as three commands rather than as one three-way
		 * choice. Each segment wears the symbol of the view it selects — `grid-dots` for icons, `menu-2` for a list,
		 * `columns-3` for columns — and the words survive where a name belongs: the toolbar ITEM's label under the
		 * switch.
		 *
		 * **AND THE PICTURES ARE ASKED FOR AS `toolbar:` AND NOT AS A BARE NAME.** `toolbar:` means "the theme that holds
		 * the UI's symbols", so the band asks for the 24-point outline the rest of this desktop draws and a machine with
		 * another icon theme still gets its own. A bare `grid-dots` would be answered by whichever theme is in charge,
		 * which for a place theme is a FILLED folder-shaped set and not this outline at all. */
		NSArray *symbols = [NSArray arrayWithObjects:@"toolbar:grid-dots", @"toolbar:menu-2",
							     @"toolbar:columns-3", nil];

		_viewSwitcher = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0.0, 0.0, 300.0, 24.0)];
		[_viewSwitcher setSegmentCount:3];
		for (i = 0; i < 3; i++) {
			NSImage *symbol = [NSImage imageNamed:[symbols objectAtIndex:(NSUInteger)i]];

			[_viewSwitcher setImage:symbol forSegment:i];
			/* A WIDTH OF ZERO IS "AS WIDE AS THE CONTENT NEEDS", which for a sixteen-point picture is a chip of the
			 * band's own height rather than the seventy points three words needed. */
			[_viewSwitcher setWidth:0.0 forSegment:i];
			[_viewSwitcher setEnabled:YES forSegment:i];
		}
		/* AND THE WHOLE SWITCH SAYS WHAT IT IS, because a segment has no room for a word of its own — the same sentence
		 * the three labels carried, said once. */
		[_viewSwitcher setToolTip:@"Icon, list or column view"];
		[_viewSwitcher setSelectedSegment:0];
		[_viewSwitcher setTarget:self];
		[_viewSwitcher setAction:@selector(viewSwitcherChanged:)];
		[_viewSwitcher sizeToFit];

		item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
		[item setLabel:@"View"];
		[item setPaletteLabel:@"View"];
		[item setView:_viewSwitcher];
		[item setMinSize:[_viewSwitcher frame].size];
		[item setMaxSize:[_viewSwitcher frame].size];
		return item;
	}
	if ([identifier isEqualToString:WSSearchFieldItemIdentifier]) {
		/* **A SEARCH FIELD IS THE FIELD, NOT A BUTTON WITH AN ICON.** `NSSearchField` is what carries the magnifier, the
		 * clear circle and the recents menu, so the toolbar supplies a VIEW — the same shape the switcher above uses —
		 * and everything a person types is the cell's business.
		 *
		 * **AND IT FILTERS AS THEY TYPE.** `-sendsWholeSearchString:` NO with `-sendsSearchStringImmediately:` YES is the
		 * pair that asks the cell to send on every keystroke; left alone the cell waits for Return, which is a search
		 * field that appears to do nothing until a person gives up and presses a key they were not told about. */
		_searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(0.0, 0.0, 200.0, 24.0)];
		/* THE PLACEHOLDER IS THE CELL'S, AND THE FIELD DOES NOT FORWARD IT IN THIS TIER — MEASURED: the message reaches
		 * NSSearchField and it raises "not implemented", which takes the window with it. */
		[[_searchField cell] setPlaceholderString:@"Search"];
		[[_searchField cell] setSendsWholeSearchString:NO];
		[[_searchField cell] setSendsSearchStringImmediately:YES];
		[_searchField setTarget:self];
		[_searchField setAction:@selector(searchFieldChanged:)];
		[_searchField setToolTip:@"Filter this folder by name"];

		item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
		[item setLabel:@"Search"];
		[item setPaletteLabel:@"Search"];
		[item setView:_searchField];
		[item setMinSize:NSMakeSize(120.0, 24.0)];
		[item setMaxSize:NSMakeSize(320.0, 24.0)];
		return item;
	}
	return nil;	/* the spacers are the toolbar's own */
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
	(void)toolbar;
	return [NSArray arrayWithObjects:WSBackItemIdentifier, WSForwardItemIdentifier,
					 NSToolbarFlexibleSpaceItemIdentifier, WSViewSwitcherItemIdentifier,
					 WSSearchFieldItemIdentifier, nil];
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
	(void)toolbar;
	return [NSArray arrayWithObjects:WSBackItemIdentifier, WSForwardItemIdentifier,
					 WSViewSwitcherItemIdentifier, WSSearchFieldItemIdentifier,
					 NSToolbarSeparatorItemIdentifier, NSToolbarSpaceItemIdentifier,
					 NSToolbarFlexibleSpaceItemIdentifier, nil];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)item
{
	SEL action = [item action];

	if (action == @selector(goBack:)) {
		return [self canGoBack];
	}
	if (action == @selector(goForward:)) {
		return [self canGoForward];
	}
	return YES;
}

/* ---- THE SIDEBAR'S DATA SOURCE AND DELEGATE -------------------------------------------------- */

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
	(void)outlineView;
	if (item == nil) {
		return (NSInteger)[_placeSections count];
	}
	if ([item isKindOfClass:[WSPlaceSection class]]) {
		return (NSInteger)[[(WSPlaceSection *)item places] count];
	}
	return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item
{
	(void)outlineView;
	if (item == nil) {
		return [_placeSections objectAtIndex:(NSUInteger)index];
	}
	return [[(WSPlaceSection *)item places] objectAtIndex:(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
	(void)outlineView;
	return [item isKindOfClass:[WSPlaceSection class]];
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
	(void)outlineView;
	(void)tableColumn;
	if ([item isKindOfClass:[WSPlaceSection class]]) {
		return [(WSPlaceSection *)item title];
	}
	return [(WSPlace *)item title];
}

- (void)outlineView:(NSOutlineView *)outlineView willDisplayCell:(id)cell
     forTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
	(void)outlineView;
	(void)tableColumn;
	if ([item isKindOfClass:[WSPlace class]]) {
		[cell setImage:[WSItemIcons iconForPath:[(WSPlace *)item path] isDirectory:YES size:16]];
	} else {
		[cell setImage:nil];
	}
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
	NSInteger row;
	id item;

	(void)notification;
	if (_syncingSidebar) {
		return;
	}
	row = [_sidebar selectedRow];
	if (row < 0) {
		return;
	}
	item = [_sidebar itemAtRow:row];
	if ([item isKindOfClass:[WSPlace class]]) {
		[self navigateToDirectory:[(WSPlace *)item path]];
	}
}

/* ---- THE FILE OPERATIONS --------------------------------------------------------------------- */

- (NSArray *)selectedItems
{
	if (_viewMode == 0) return [_iconView selectedItems];
	if (_viewMode == 1) return (_listView != nil) ? [_listView selectedItems] : [NSArray array];
	return (_columnView != nil) ? [_columnView selectedItems] : [NSArray array];
}

- (NSArray *)selectedPaths
{
	NSArray *items = [self selectedItems];
	NSMutableArray *paths = [[NSMutableArray alloc] init];
	NSUInteger i;

	for (i = 0; i < [items count]; i++) {
		[paths addObject:[[items objectAtIndex:i] path]];
	}
	return [paths autorelease];
}

- (void)progress:(NSUInteger)completed total:(NSUInteger)total path:(NSString *)path
{
	if (total <= 1) {
		return;
	}
	if (_progressWindow == nil) {
		_progressWindow = [[WSProgressWindow alloc] init];
	}
	[_progressWindow setCompleted:completed total:total path:path];
	[_progressWindow show];
}

- (void)finishOperation
{
	[_progressWindow hide];
	[self refresh];
	/* **AND THE WINDOW IS PAINTED NOW, NOT WHEN THE RUN LOOP NEXT COMES ROUND.** A command that arrived through a menu's
	 * tracking loop ends with the rows already in the model and the damage merely recorded: MEASURED, a folder created
	 * from the context menu was on disk at once, was in the model 29 ms later, and appeared on the glass a beat after
	 * that. Flushing the damage here makes the answer to "where did it go" the same frame as the command. */
	[[self window] displayIfNeeded];
}

/* **THE LISTING IS THE SELECTION OR THE FOLDER.** A file manager prints what it is showing: with items selected, those
 * items; with nothing selected, every item the window is looking at. An empty folder has nothing to print, and the menu
 * row is disabled there rather than printing a blank page. */
- (NSArray *)printablePaths
{
	NSArray *selected = [self selectedPaths];
	NSMutableArray *paths;
	NSArray *items;
	NSUInteger i;

	if ([selected count] > 0) {
		return selected;
	}
	paths = [NSMutableArray array];
	items = [_model items];
	for (i = 0; i < [items count]; i++) {
		[paths addObject:[[items objectAtIndex:i] path]];
	}
	return paths;
}

/* **AND THE VERB ITSELF CALLS THE LAUNCH'S DOOR.** `-application:printFiles:` is what a print request from outside
 * reaches; calling it here means the menu and the request take one path, and that the delegate's reply is used
 * (NSApplication turns it into the open-or-print reply). */
- (void)printSelection:(id)sender
{
	NSArray *paths = [self printablePaths];

	(void)sender;
	if ([paths count] == 0) {
		return;
	}
	[[NSApplication sharedApplication] application:nil printFiles:paths];
}

/* **WHERE A COMMAND THAT MAKES SOMETHING PUTS IT.** A column view shows a chain of folders at once, so the folder a menu
 * was raised in is not necessarily the folder the window opened on: "new directory in the third column" belongs in the
 * third column's directory, and MEASURED it was landing in the first. Every other mode shows one folder, which is the
 * window's own, and the browser says which one for itself. */
- (NSString *)cg_commandDirectory
{
	if (_viewMode == 2 && _columnView != nil) {
		return [_columnView cg_commandDirectory];
	}
	return _directory;
}

- (void)newFolder:(id)sender
{
	(void)sender;
	(void)[_fileOperations createFolderInDirectory:[self cg_commandDirectory] name:nil error:NULL];
	[self finishOperation];
}

- (void)duplicate:(id)sender
{
	(void)sender;
	(void)[_fileOperations duplicatePaths:[self selectedPaths] inDirectory:[self cg_commandDirectory] error:NULL];
	[self finishOperation];
}

- (void)compress:(id)sender
{
	(void)sender;
	(void)[_fileOperations compressPaths:[self selectedPaths] inDirectory:[self cg_commandDirectory] error:NULL];
	[self finishOperation];
}

/* ============================================================================================ *
 * THE SHARED COMMANDS: WHAT A CONTEXT MENU ASKS OF WHICHEVER VIEW IS SHOWING.                      *
 *                                                                                                *
 * **THE WINDOW OWNS THESE BECAUSE THE WINDOW OWNS THE SELECTION'S MEANING**, not the pixels: `-selectedItems`
 * already answers per view mode, `_fileOperations` is the window's manager (its progress plate and its undo
 * manager), and `-finishOperation` is the ending every one of them owes. So a list row, a column cell and an icon
 * all raise the same menu aimed at THIS object, and there is one implementation of Paste rather than four.
 *
 * **THE VIEWS THAT CAN ANSWER FOR THEMSELVES STILL DO.** `WSIconView` and `WSDesktopView` implement Cut, Copy,
 * Paste, Rename and New Folder themselves — they were first and their tests measure them — so in Icon mode the
 * first responder answers before the chain reaches here. In List and Column mode it does, because neither of those
 * views has any of these commands.
 * ============================================================================================ */

- (void)cut:(id)sender
{
	(void)sender;
	WSItemCutPathsToPasteboard([self selectedPaths]);
}

- (void)copy:(id)sender
{
	(void)sender;
	WSItemCopyPathsToPasteboard([self selectedPaths]);
}

- (void)paste:(id)sender
{
	BOOL wasCut = NO;
	NSArray *paths = WSItemClipboardPaths(&wasCut);

	(void)sender;
	if ([paths count] == 0) {
		return;
	}
	if (wasCut) {
		(void)[_fileOperations movePaths:paths toDirectory:[self cg_commandDirectory] error:NULL];
		WSItemClipboardForget();
	} else {
		(void)[_fileOperations copyPaths:paths toDirectory:[self cg_commandDirectory] error:NULL];
	}
	[self finishOperation];
}

/* **RENAME IS THE SHOWING VIEW'S OWN FIELD, AND THE COLUMN VIEW HAS NONE.** A browser cell has no editor in this tier,
 * so the row is grey there (`-validateMenuItem:` says so) rather than a command that would silently do nothing. */
- (void)rename:(id)sender
{
	(void)sender;
	if (_viewMode == 0) {
		(void)[_iconView beginRenamingSelectedItem];
	} else if (_viewMode == 1) {
		(void)[_listView beginEditingSelectedName];
	}
}

/* **NEW FOLDER WITH SELECTION GATHERS WHAT IS HELD INTO A FOLDER OF ITS OWN**, the reference file manager's own way to
 * make a set out of a selection: the folder is made in the window's directory (its name made unique by W6) and the
 * selection moves into it. */
- (void)newFolderWithSelection:(id)sender
{
	NSArray *paths = [self selectedPaths];
	NSString *made;

	(void)sender;
	if ([paths count] == 0) {
		return;
	}
	made = [_fileOperations createFolderInDirectory:_directory name:@"New Folder with Selection" error:NULL];
	if (made == nil) {
		return;
	}
	(void)[_fileOperations movePaths:paths toDirectory:made error:NULL];
	[self finishOperation];
}

/* AND SELECT ALL IS THE SHOWING VIEW'S, because "all" is a fact about a grid, a tree or a column rather than about the
 * window. A browser has no such door, so the row is grey in Column mode. */
- (void)selectAll:(id)sender
{
	(void)sender;
	if (_viewMode == 0) {
		[_iconView selectAll:nil];
	} else if (_viewMode == 1) {
		[_listView selectAll:nil];
	}
}

- (void)moveToTrash:(id)sender
{
	(void)sender;
	(void)[_fileOperations movePathsToTrash:[self selectedPaths] error:NULL];
	[self finishOperation];
}

/* **PUT BACK IS THE TRASH'S OWN COMMAND, AND IT IS THE RECORD THAT ANSWERS IT.** A trashed item keeps the path it came
 * from in its Put Back record, beside it under `.putback/`; nothing here guesses from a name. The selection is matched
 * against those records by where the item SITS — the only thing the window is looking at — and `WSTrash` does the move,
 * which is the same door the undo of "Move to Trash" already uses.
 *
 * An item with no record (something another program put in the bin, or a record somebody deleted) is simply not in the
 * list: there is nowhere to send it, and inventing a destination would be worse than doing nothing. */
/* THE SELECTION'S RECORDS, newest first and in the records' own order — the one answer both the command and its
 * validation ask for. */
- (NSArray *)fn_trashRecordsForSelection
{
	NSArray *paths = [self selectedPaths];
	NSArray *records = [[_fileOperations trash] items];
	NSMutableArray *items = [[NSMutableArray alloc] init];
	NSUInteger i;
	NSUInteger j;

	for (i = 0; i < [records count]; i++) {
		WSTrashItem *item = [records objectAtIndex:i];

		for (j = 0; j < [paths count]; j++) {
			if ([[item trashPath] isEqual:[paths objectAtIndex:j]]) {
				[items addObject:item];
				break;
			}
		}
	}
	return [items autorelease];
}

- (void)putBack:(id)sender
{
	NSArray *items = [self fn_trashRecordsForSelection];

	(void)sender;
	if ([items count] == 0) {
		return;
	}
	(void)[_fileOperations putBackTrashItems:items error:NULL];
	[self finishOperation];
}

- (BOOL)isTrashDirectory { return _isTrashDirectory; }

- (WSFileOperations *)fileOperations { return _fileOperations; }
- (void)setFileOperations:(WSFileOperations *)operations
{
	if (operations == _fileOperations) {
		return;
	}
	[operations retain];
	[_fileOperations release];
	_fileOperations = operations;
}

- (void)undo:(id)sender
{
	(void)sender;
	if ([_undoManager canUndo]) {
		[_undoManager undo];
		[self finishOperation];
	}
}

- (void)redo:(id)sender
{
	(void)sender;
	if ([_undoManager canRedo]) {
		[_undoManager redo];
		[self finishOperation];
	}
}

/* ---- THE WINDOW AND THE MENUS --------------------------------------------------------------- */

/* **THE SIDEBAR KEEPS ITS WIDTH, AND THE CONTENT ABSORBS THE WINDOW'S RESIZE.** Without this delegate answer the
 * split view scales BOTH panes by the same fraction, so a wider window widens the places list as well as the files.
 * The divider is still free to move the boundary: this only decides which pane grows when the SPLIT VIEW does. */
- (BOOL)splitView:(NSSplitView *)splitView shouldAdjustSizeOfSubview:(NSView *)view
{
	(void)splitView;
	return (view == _contentScroll);
}

/* THE PANES HAVE MOVED — a window resize, a divider drag, or the initial `-adjustSubviews`. The documents inside
 * the content pane follow the new clip bounds here, after the split view has finished writing the pane frames. */
- (void)splitViewDidResizeSubviews:(NSNotification *)notification
{
	(void)notification;
	/* **A DIVIDER DRAG IS FRAMES, NOT DOCUMENT LAYOUT.** The split view sets the panes' frames on every motion, and
	 * the documents do not need to be re-tiled until the drag ends; re-laying the browser out for every motion made
	 * the sidebar gutter crawl while the browser's own gutter was smooth. The split view posts one final
	 * did-resize after it clears its dragging flag, and that is the pass that reaches here. */
	if ([_split cg_isDraggingDivider]) {
		return;
	}
	/* **AND THE PLACES PANE'S WIDTH IS THE PERSON'S, ONCE THEY HAVE DRAGGED IT.** The pass that reaches here after a drag
	 * writes the pane's own width down; a window resize also reaches here and writes the same number again, which is a
	 * comparison `-cg_setSidebarWidth:` makes cheap rather than a second path. */
	if (_sidebarScroll != nil && [_sidebarScroll superview] == _split) {
		[WSFileWindowController cg_setSidebarWidth:NSWidth([_sidebarScroll frame])];
	}
	[self refreshContentSizes];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	SEL action = [menuItem action];

	if (action == @selector(goBack:)) {
		return [self canGoBack];
	}
	if (action == @selector(goForward:)) {
		return [self canGoForward];
	}
	if (action == @selector(cg_useIconView:)) {
		return YES;
	}
	if (action == @selector(cg_useListView:)) {
		return YES;
	}
	if (action == @selector(cg_useColumnView:)) {
		return YES;
	}
	if (action == @selector(goToEnclosingFolder:)) {
		return [_directory isEqual:@"/"] ? NO : YES;
	}
	if (action == @selector(goHome:) || action == @selector(goToDesktop:)
	    || action == @selector(goToApplications:) || action == @selector(goToComputer:)) {
		return YES;
	}
	if (action == @selector(newFolder:)) {
		return YES;
	}
	if (action == @selector(newFolderWithSelection:)) {
		return [[self selectedItems] count] > 0;
	}
	if (action == @selector(cut:) || action == @selector(copy:)) {
		return [[self selectedItems] count] > 0;
	}
	if (action == @selector(paste:)) {
		return [WSItemClipboardPaths(NULL) count] > 0;
	}
	if (action == @selector(rename:)) {
		return _viewMode != 2 && [[self selectedItems] count] == 1;
	}
	if (action == @selector(selectAll:)) {
		/* **A BROWSER HAS NO SELECT-ALL IN THIS TIER**, so the row is grey rather than a command that would do
		 * nothing: the icon grid and the tree both have the door, the column browser does not. */
		return _viewMode != 2 && [self itemCount] > 0;
	}
	if (action == @selector(printSelection:)) {
		return [[self printablePaths] count] > 0;
	}
	if (action == @selector(duplicate:) || action == @selector(compress:)
	    || action == @selector(moveToTrash:)) {
		return [[self selectedItems] count] > 0;
	}
	if (action == @selector(putBack:)) {
		/* **A ROW THE WINDOW IS NOT SHOWING IS A ROW IT CANNOT ANSWER** — the trash has the way back, an ordinary folder
		 * has none, and the menu's own update walk draws the difference. **AND NEITHER IS A ROW WITH NOWHERE TO GO**:
		 * something another program put in the bin has no Put Back record, so the row is grey rather than a command that
		 * would do nothing when pressed. */
		return _isTrashDirectory && [[self fn_trashRecordsForSelection] count] > 0;
	}
	if (action == @selector(undo:)) {
		return [_undoManager canUndo];
	}
	if (action == @selector(redo:)) {
		return [_undoManager canRedo];
	}
	return YES;
}

/* ============================================================================================ *
 * THE TOOLBAR'S WORDS, WHICH ARE ONE PREFERENCE AND NOT A PER-WINDOW CHOICE.                     *
 *                                                                                                *
 * **THE SAME ARRANGEMENT FORGE'S PROJECT WINDOW HAS**, because it is the same question: a band whose items are a verb and
 * a picture says both usefully the first time and clutters every time after, so the View menu offers to put the words
 * away, and the answer belongs to the APPLICATION rather than to the window a person happened to press it in. It is
 * `NSToolbar`'s own vocabulary — `IconAndLabel` against `IconOnly` — so nothing here invents a second notion of a
 * toolbar's face.
 * ============================================================================================ */

/* **THE DEFAULT VIEW MODE: 0 Icon, 1 List, 2 Column**, and anything else in the defaults reads as Icon rather than as a
 * window with no view at all. */
+ (CGFloat)cg_sidebarWidth
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	double width;

	if (defaults == nil || [defaults objectForKey:WSSidebarWidthKey] == nil) {
		return WS_SIDEBAR_WIDTH;
	}
	width = [defaults doubleForKey:WSSidebarWidthKey];
	if (width < WS_SIDEBAR_MIN_WIDTH || width > WS_SIDEBAR_MAX_WIDTH) {
		return WS_SIDEBAR_WIDTH;
	}
	return (CGFloat)width;
}

+ (void)cg_setSidebarWidth:(CGFloat)width
{
	if (width < WS_SIDEBAR_MIN_WIDTH || width > WS_SIDEBAR_MAX_WIDTH) {
		return;
	}
	[[NSUserDefaults standardUserDefaults] setDouble:(double)width forKey:WSSidebarWidthKey];
}

+ (NSInteger)cg_defaultViewMode
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSInteger mode;

	if (defaults == nil || [defaults objectForKey:WSDefaultViewModeKey] == nil) {
		return 0;
	}
	mode = [defaults integerForKey:WSDefaultViewModeKey];
	if (mode < 0 || mode > 2) {
		return 0;
	}
	return mode;
}

+ (void)cg_setDefaultViewMode:(NSInteger)mode
{
	if (mode < 0 || mode > 2) {
		return;
	}
	[[NSUserDefaults standardUserDefaults] setInteger:mode forKey:WSDefaultViewModeKey];
}

+ (BOOL)cg_toolbarLabelsVisible
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

	if ([defaults objectForKey:WSToolbarLabelsKey] == nil) {
		return YES;		/* a window nobody has chosen for keeps what this application always drew */
	}
	return [defaults boolForKey:WSToolbarLabelsKey];
}

+ (void)cg_setToolbarLabelsVisible:(BOOL)visible
{
	[[NSUserDefaults standardUserDefaults] setBool:visible forKey:WSToolbarLabelsKey];
}

- (void)cg_applyToolbarLabels
{
	[_toolbar setDisplayMode:[WSFileWindowController cg_toolbarLabelsVisible]
				  ? NSToolbarDisplayModeIconAndLabel : NSToolbarDisplayModeIconOnly];
}

/* **THE TICK DESCRIBES THE PREFERENCE NOW, NOT THE LAST PRESS.** The menu asks this on its way to opening, so a value
 * changed by another window — or by an edit to the defaults store — is never drawn stale. */
+ (void)cg_showToolbarLabelsStateOn:(NSMenuItem *)item
{
	if (item != nil) {
		[item setState:[self cg_toolbarLabelsVisible] ? NSOnState : NSOffState];
	}
}

/* ---- THE SEAMS ------------------------------------------------------------------------------ */

- (NSOutlineView *)cg_sidebarOutline { return _sidebar; }
- (NSPathControl *)cg_pathControl { return _pathBar; }
- (NSTextField *)cg_statusField { return _status; }
- (WSIconView *)cg_iconView { return _iconView; }
- (WSListView *)cg_listView { return _listView; }
- (WSColumnView *)cg_columnView { return _columnView; }
/* The plate a file operation puts up while it runs, so a probe can see that the operation ENDED: the window is closed
 * by `-finishOperation`, and a command that ran an operation without that ending left it on the glass. */
- (WSProgressWindow *)cg_progressWindow
{
	return _progressWindow;
}

- (void)searchFieldChanged:(id)sender
{
	(void)sender;
	/* **THE FILTER IS THE MODEL'S AND THE WINDOW ONLY HANDS IT OVER.** `-setNameFilter:` changes what `-items` answers,
	 * and every view keeps the rows it was given — so the model goes back to whichever view is showing, through the same
	 * `-setModel:` navigation uses. The status bar and the path bar read the model already, so their counts follow
	 * without being told. */
	[_model setNameFilter:[_searchField stringValue]];
	if (_viewMode == 0) {
		[_iconView setModel:_model];
		[self refreshIconFrame];
	} else if (_viewMode == 1 && _listView != nil) {
		[_listView setModel:_model];
		[_listView reloadData];
		[_listView tile];
	} else if (_viewMode == 2 && _columnView != nil) {
		[_columnView setModel:_model];
	}
	[self refresh];
}

- (NSSearchField *)cg_searchField { return _searchField; }
- (NSSegmentedControl *)cg_viewSwitcher { return _viewSwitcher; }
- (NSSplitView *)cg_splitView { return _split; }

@end
