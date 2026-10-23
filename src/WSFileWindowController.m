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
#import "WSItemIcons.h"
#import "WSItemModel.h"
#import "WSPlaces.h"
#import "WSProgressWindow.h"
#import "WSTrash.h"

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

	[self buildPathBar];
	[self buildContentAndSidebar];
	[self buildStatusBar];
	[self installStripConstraints];

	[self buildToolbar];
	[self refresh];
	return self;
}

- (void)dealloc
{
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

	_sidebarScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WS_SIDEBAR_WIDTH, 500.0)];
	[_sidebarScroll setHasVerticalScroller:YES];
	[_sidebarScroll setAutohidesScrollers:YES];
	[_sidebarScroll setBorderType:NSNoBorder];
	[_sidebarScroll setDrawsBackground:YES];
	_sidebar = [[NSOutlineView alloc] initWithFrame:[[_sidebarScroll contentView] bounds]];
	column = [[NSTableColumn alloc] initWithIdentifier:@"place"];
	[column setWidth:WS_SIDEBAR_WIDTH - 20.0];
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

	_contentScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(WS_SIDEBAR_WIDTH, 0.0,
									 900.0 - WS_SIDEBAR_WIDTH, 500.0)];
	[_contentScroll setHasVerticalScroller:YES];
	/* **A BAR THE DOCUMENT DOES NOT NEED STEPS ASIDE, the same rule as the sidebar's and the browser's columns.
	 * Without autohide a configured scroller is always a subview, so the icon grid wore a full-height bar in a
	 * folder whose rows already fit. */
	[_contentScroll setAutohidesScrollers:YES];
	[_contentScroll setBorderType:NSNoBorder];
	[_contentScroll setDrawsBackground:YES];
	_iconView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0,
								     900.0 - WS_SIDEBAR_WIDTH, 500.0)
						    model:_model];
	[_iconView setDelegate:(id <WSIconViewDelegate>)self];
	[_iconView setFileOperations:_fileOperations];
	[_contentScroll setDocumentView:_iconView];

	[_split setDelegate:self];
	[_split addSubview:_sidebarScroll];
	[_split addSubview:_contentScroll];
	[_split adjustSubviews];
	[_split setPosition:WS_SIDEBAR_WIDTH ofDividerAtIndex:0];

	[[window contentView] addSubview:_pathBar];
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

	[NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
		[[_pathBar leadingAnchor] constraintEqualToAnchor:[content leadingAnchor]],
		[[_pathBar trailingAnchor] constraintEqualToAnchor:[content trailingAnchor]],
		[[_pathBar topAnchor] constraintEqualToAnchor:[content topAnchor]],
		[[_pathBar heightAnchor] constraintEqualToConstant:WS_PATH_BAR_HEIGHT],

		[[_split leadingAnchor] constraintEqualToAnchor:[content leadingAnchor]],
		[[_split trailingAnchor] constraintEqualToAnchor:[content trailingAnchor]],
		[[_split topAnchor] constraintEqualToAnchor:[_pathBar bottomAnchor]],
		[[_split bottomAnchor] constraintEqualToAnchor:[_status topAnchor]],

		[[_status leadingAnchor] constraintEqualToAnchor:[content leadingAnchor]],
		[[_status trailingAnchor] constraintEqualToAnchor:[content trailingAnchor]],
		[[_status bottomAnchor] constraintEqualToAnchor:[content bottomAnchor]],
		[[_status heightAnchor] constraintEqualToConstant:WS_STATUS_BAR_HEIGHT],
		nil]];
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
	[_toolbar setDisplayMode:NSToolbarDisplayModeIconAndLabel];
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

- (void)refresh
{
	NSInteger count = [self itemCount];
	NSString *title = [_directory lastPathComponent];

	[_iconView setModel:_model];
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
	[_pathBar setURL:[NSURL fileURLWithPath:_directory]];
	[_status setStringValue:[NSString stringWithFormat:@"%ld %@", (long)count,
				  (count == 1) ? @"item" : @"items"]];
	if (title == nil || [title length] == 0) {
		title = _directory;
	}
	[[self window] setTitle:title];
	[self refreshIconFrame];
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
	[_directory release];
	_directory = [standard copy];
	[_model release];
	_model = [[WSItemModel alloc] initWithDirectory:_directory];
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
		[_contentScroll setDocumentView:_columnView];
		fn_resetContentScroll(_contentScroll);
		[_columnView setFrameSize:[[_contentScroll contentView] bounds].size];
	}
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

- (void)columnViewDidChangeModel:(WSColumnView *)view
{
	(void)view;
	[self refresh];
}

/* **A DOCUMENT OPENS THROUGH THE WORKSPACE'S OWN APPKIT DOOR, NOT THROUGH THE SEAM DIRECTLY.** `NSWorkspace` is this
 * stack's face over Launch Services — `WORKSPACE-PLAN.md` puts it in the AppKit rather than here — so the file manager
 * asks it and the policy (which applications are registered, what a type resolves to, what a refusal looks like) stays
 * in the one place that owns it. MEASURED: this method used to build a CFURL and call `LSOpenCFURLRef` itself, which
 * meant the file window had a second copy of the launch decision and no way to see the AppKit's answer. */
- (void)openItem:(WSItem *)item
{
	if ([item isDirectory]) {
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
		NSArray *labels = [NSArray arrayWithObjects:@"Icon", @"List", @"Column", nil];

		_viewSwitcher = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0.0, 0.0, 300.0, 24.0)];
		[_viewSwitcher setSegmentCount:3];
		for (i = 0; i < 3; i++) {
			[_viewSwitcher setLabel:[labels objectAtIndex:(NSUInteger)i] forSegment:i];
			[_viewSwitcher setWidth:70.0 forSegment:i];
			[_viewSwitcher setEnabled:YES forSegment:i];
		}
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
	return nil;	/* the spacers are the toolbar's own */
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
	(void)toolbar;
	return [NSArray arrayWithObjects:WSBackItemIdentifier, WSForwardItemIdentifier,
					 NSToolbarFlexibleSpaceItemIdentifier, WSViewSwitcherItemIdentifier, nil];
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
	(void)toolbar;
	return [NSArray arrayWithObjects:WSBackItemIdentifier, WSForwardItemIdentifier,
					 WSViewSwitcherItemIdentifier, NSToolbarSeparatorItemIdentifier,
					 NSToolbarSpaceItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier, nil];
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

- (void)newFolder:(id)sender
{
	(void)sender;
	(void)[_fileOperations createFolderInDirectory:_directory name:nil error:NULL];
	[self finishOperation];
}

- (void)duplicate:(id)sender
{
	(void)sender;
	(void)[_fileOperations duplicatePaths:[self selectedPaths] inDirectory:_directory error:NULL];
	[self finishOperation];
}

- (void)compress:(id)sender
{
	(void)sender;
	(void)[_fileOperations compressPaths:[self selectedPaths] inDirectory:_directory error:NULL];
	[self finishOperation];
}

- (void)moveToTrash:(id)sender
{
	(void)sender;
	(void)[_fileOperations movePathsToTrash:[self selectedPaths] error:NULL];
	[self finishOperation];
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
	if (action == @selector(printSelection:)) {
		return [[self printablePaths] count] > 0;
	}
	if (action == @selector(duplicate:) || action == @selector(compress:)
	    || action == @selector(moveToTrash:)) {
		return [[self selectedItems] count] > 0;
	}
	if (action == @selector(undo:)) {
		return [_undoManager canUndo];
	}
	if (action == @selector(redo:)) {
		return [_undoManager canRedo];
	}
	return YES;
}

/* ---- THE SEAMS ------------------------------------------------------------------------------ */

- (NSOutlineView *)cg_sidebarOutline { return _sidebar; }
- (NSPathControl *)cg_pathControl { return _pathBar; }
- (NSTextField *)cg_statusField { return _status; }
- (WSIconView *)cg_iconView { return _iconView; }
- (WSListView *)cg_listView { return _listView; }
- (WSColumnView *)cg_columnView { return _columnView; }
- (NSSegmentedControl *)cg_viewSwitcher { return _viewSwitcher; }
- (NSSplitView *)cg_splitView { return _split; }

@end
