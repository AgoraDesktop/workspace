/*
 * file_window — the W2 shell: one folder, one model, and every strip reading it.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **WHAT THIS PROVES IS THE SHELL'S ONE RULE: the title, the path bar, the status bar and the icon view are four
 * renderings of ONE `WSItemModel`.** A navigation replaces that model and every strip follows; the history's
 * Back/Forward is the only thing that decides which folder is shown; and a second controller is a second folder
 * with its own model and its own cursor. Offscreen: no compositor, no click, no menu tracking.
 */
#import "WSColumnView.h"
#import "WSIconView.h"
#import "WSFileWindowController.h"
#import "WSItemModel.h"
#import "WSPlaces.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSBrowser.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSOutlineView.h>
#import <AppKit/NSPathControl.h>
#import <AppKit/NSScroller.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSSegmentedControl.h>
#import <AppKit/NSSplitView.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSToolbar.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <unistd.h>

static int s_failed;

static void check(int ok, const char *name)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", name);
	if (!ok) {
		s_failed++;
	}
}

static int near(double a, double b)
{
	return a > b - 0.01 && a < b + 0.01;
}

static NSString *tempRoot(void)
{
	/* `/tmp` BY NAME: this Foundation's `NSTemporaryDirectory()` answers `/System/Temporary Files`, which is not a
	 * writable directory on this machine. The probe owns its tree and removes it. */
	return [@"/tmp" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"workspace-file-window-%d", (int)getpid()]];
}

static BOOL makeDirectory(NSString *path)
{
	return [[NSFileManager defaultManager] createDirectoryAtPath:path
						 withIntermediateDirectories:YES
								  attributes:nil error:NULL];
}

static BOOL makeFile(NSString *path)
{
	return [[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data] attributes:nil];
}

static NSString *placeTitleAt(WSFileWindowController *controller, NSInteger section, NSInteger child)
{
	NSOutlineView *outline = [controller cg_sidebarOutline];
	id root = [controller outlineView:outline child:section ofItem:nil];
	id item = [controller outlineView:outline child:child ofItem:root];

	return [(WSPlace *)item title];
}

int main(void)
{
	NSApplication *application = [NSApplication sharedApplication];
	NSString *root = tempRoot();
	NSString *folderA = [root stringByAppendingPathComponent:@"A Folder"];
	NSString *subOne = [root stringByAppendingPathComponent:@"Sub One"];
	NSString *subTwo = [root stringByAppendingPathComponent:@"Sub Two"];
	WSFileWindowController *first;
	WSFileWindowController *second;
	NSOutlineView *outline;
	NSMenuItem *backItem;
	NSMenuItem *listItem;
	NSMenuItem *columnItem;

	setvbuf(stdout, NULL, _IONBF, 0);
	[application finishLaunching];

	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	check(makeDirectory(root), "the probe made its temporary tree");
	makeDirectory(folderA);
	makeDirectory(subOne);
	makeDirectory(subTwo);
	makeFile([root stringByAppendingPathComponent:@"b.txt"]);
	makeFile([root stringByAppendingPathComponent:@".hidden"]);
	makeFile([subOne stringByAppendingPathComponent:@"c.txt"]);

	first = [[WSFileWindowController alloc] initWithDirectory:root];
	check(first != nil && [first window] != nil, "a directory makes a window");
	check([[first directory] isEqual:root], "and the controller holds the folder it was given");
	check([first itemCount] == 4, "the model counts the two folders and one file, and not the hidden one");
	check([[[first cg_statusField] stringValue] isEqual:@"4 items"], "the status bar reports the model's count");
	check([[[[first cg_pathControl] URL] path] isEqual:root], "the path bar holds the same folder");
	check([[[first window] title] isEqual:[root lastPathComponent]],
	      "the title is the folder's own name");
	check([first cg_iconView] != nil, "the icon view exists");
	check([[first cg_iconView] itemCount] == 4, "the icon view shows the model's items");
	{
		NSScrollView *content = [[first cg_iconView] enclosingScrollView];

		check([content autohidesScrollers] && [[content verticalScroller] isHidden],
		      "and the four icons fit, so the content pane's bar is hidden");
	}
	check([[first cg_viewSwitcher] segmentCount] == 3, "the switcher has three segments");
	check([[first cg_viewSwitcher] selectedSegment] == 0, "with Icon selected");
	check([[first cg_viewSwitcher] isEnabledForSegment:0]
	      && [[first cg_viewSwitcher] isEnabledForSegment:1]
	      && [[first cg_viewSwitcher] isEnabledForSegment:2],
	      "all three views are enabled");
	check([[[first window] toolbar] items] != nil && [[[[first window] toolbar] items] count] >= 4,
	      "the toolbar has its items");
	check(![first canGoBack] && ![first canGoForward], "a new window has nowhere to go back or forward to");

	outline = [first cg_sidebarOutline];
	check([first cg_splitView].dividerStyle == NSSplitViewDividerStylePaneSplitter
	      && [[first cg_splitView] dividerThickness] == 18.0,
	      "the sidebar's divider is the split view's eighteen-point gutter");
	check([outline numberOfRows] == 6, "the sidebar expands two sections and their four places");
	{
		NSScrollView *sidebarScroll = [outline enclosingScrollView];

		check([sidebarScroll autohidesScrollers] && [[sidebarScroll verticalScroller] isHidden],
		      "and its six rows fit, so the sidebar's bar is hidden");
	}
	check([first outlineView:outline numberOfChildrenOfItem:nil] == 2, "the sidebar has two sections");
	check([placeTitleAt(first, 0, 0) isEqual:@"Desktop"]
	      && [placeTitleAt(first, 0, 1) isEqual:@"Home"]
	      && [placeTitleAt(first, 0, 2) isEqual:@"Applications"],
	      "PLACES is Desktop, Home and Applications");
	check([placeTitleAt(first, 1, 0) isEqual:@"Computer"], "and DEVICES is Computer");

	backItem = [[NSMenuItem alloc] initWithTitle:@"Back" action:@selector(goBack:) keyEquivalent:@""];
	listItem = [[NSMenuItem alloc] initWithTitle:@"as List" action:@selector(cg_useListView:) keyEquivalent:@""];
	columnItem = [[NSMenuItem alloc] initWithTitle:@"as Columns" action:@selector(cg_useColumnView:) keyEquivalent:@""];
	check(![first validateMenuItem:backItem], "Back is disabled at the first location");
	check([first validateMenuItem:listItem], "List is enabled (W4)");
	check([first validateMenuItem:columnItem], "and Columns is enabled (W5)");

	/* THE SWITCHER ACTUALLY SWAPS THE CONTENT VIEW, AND THE LIST READS THE SAME MODEL. */
	[first cg_useListView:nil];
	check([first viewMode] == 1 && [first cg_listView] != nil
	      && [[first cg_listView] numberOfRows] == 4,
	      "choosing List builds the outline and it has the model's four rows");
	check([[[first cg_listView] enclosingScrollView] autohidesScrollers]
	       && [[[[first cg_listView] enclosingScrollView] verticalScroller] isHidden],
	      "and its four rows fit, so the shared content bar stays hidden in list mode too");
	[first cg_useColumnView:nil];
	check([first viewMode] == 2 && [first cg_columnView] != nil
	      && [[[first cg_columnView] cg_browser] numberOfRowsInColumn:0] == 4,
	      "choosing Column builds the browser over the same four items");
	[first cg_useIconView:nil];
	check([first viewMode] == 0, "and choosing Icon returns to the grid");

	/* **AND COLUMN -> ICON -> COLUMN REBUILDS THE SAME GEOMETRY.** The browser's 256-slot pool and its per-column
	 * scroll views are reused across the swap; the columns must come back at their own origins, not stacked or
	 * left at a stale clip offset. */
	/* THE ICON GRID IS SCROLLED BEFORE THE SWAP: the clip view must not hand that offset to the browser. */
	{
		NSScrollView *content = [[first cg_iconView] enclosingScrollView];
		NSClipView *clip = (NSClipView *)[content contentView];

		[clip scrollToPoint:NSMakePoint(0.0, 50.0)];
		[content reflectScrolledClipView:clip];
	}
	[first cg_useColumnView:nil];
	{
		NSBrowser *browser = [[first cg_columnView] cg_browser];
		NSScrollView *firstColumn = [browser cg_scrollViewForColumn:0];
		NSScrollView *secondColumn = [browser cg_scrollViewForColumn:1];
		NSView *document = [browser cg_documentView];
		CGFloat expectedSecond = [browser widthOfColumn:0] + 18.0;

		check([browser cg_columnCount] == 256 && [browser cg_activeColumnCount] == 1
		      && [browser numberOfRowsInColumn:0] == 4,
		      "column comes back with its pool and the model's four rows");
		check(firstColumn != nil && [firstColumn frame].origin.x == 0.0
		      && [firstColumn frame].size.width == [browser widthOfColumn:0],
		      "the first column is at the document's origin and its own width");
		check(secondColumn != nil && [secondColumn frame].origin.x == expectedSecond,
		      "the empty column after it starts at the gutter, not on top of the root");
		check(document != nil && [document superview] != nil
		      && [[document superview] bounds].origin.x == 0.0,
		      "and the browser's clip view is back at the first column");
	}
	[first cg_useIconView:nil];

	/* **A DOUBLE-CLICK ON A FOLDER IS A NAVIGATION.** The first icon is at the grid's first cell; the event is
	 * converted through the view so the scroll view's own placement cannot change the answer. */
	{
		WSIconView *icons = [first cg_iconView];
		NSPoint inWindow = [icons convertPoint:NSMakePoint(30.0, 30.0) toView:nil];
		NSEvent *down = [NSEvent mouseEventWithType:NSLeftMouseDown location:inWindow
					       modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
					      eventNumber:0 clickCount:2 pressure:1.0f];

		[icons mouseDown:down];
	}
	check([[first directory] isEqual:folderA] || [[first directory] hasSuffix:@"A Folder"],
	      "double-clicking the first icon opens that folder in the same window");
	check([first itemCount] == 0 && [[[first cg_statusField] stringValue] isEqual:@"0 items"],
	      "the empty folder updates the model, the icon view and the status bar together");
	check([first canGoBack] && ![first canGoForward], "and the navigation is one Back away");

	[first goBack:nil];
	check([[first directory] isEqual:root] && [first itemCount] == 4, "Back returns to the four-item folder");
	check([first canGoForward], "and Forward is now possible");
	[first goForward:nil];
	check([[first directory] isEqual:folderA], "Forward returns to the empty folder");

	[first goBack:nil];
	[first navigateToDirectory:subOne];
	check([first itemCount] == 1 && [[[first cg_statusField] stringValue] isEqual:@"1 item"],
	      "a second navigation shows one item, with the singular word");
	check([first canGoBack] && ![first canGoForward], "and it truncates the forward entry it branched from");

	/* THE PATH BAR AND THE MODEL ARE THE SAME FOLDER, after every navigation above. */
	check([[[[first cg_pathControl] URL] path] isEqual:subOne], "the path bar followed every navigation");

	/* W6: THE FILE MENU'S NEW FOLDER GOES THROUGH THE MANAGER, AND UNDO TAKES IT BACK. */
	{
		NSMenuItem *newFolderItem = [[NSMenuItem alloc] initWithTitle:@"New Folder"
								     action:@selector(newFolder:) keyEquivalent:@""];
		NSInteger before = [first itemCount];

		check([first validateMenuItem:newFolderItem], "New Folder is enabled");
		[first newFolder:nil];
		check([first itemCount] == before + 1, "New Folder adds the folder to the model");
		[first undo:nil];
		check([first itemCount] == before, "and Undo removes it again");
		[newFolderItem release];
	}

	/* A WINDOW IS A SHELL, SO IT RESIZES. The three strips are placed by Auto Layout, not by a resize hook:
	 * path bar at the top, status at the bottom, the split view between them, and the split's delegate keeps the
	 * sidebar's width while the content pane takes the rest. The icon view inside the scroll view follows the
	 * clip view's new width. */
	{
		NSView *sidebarPane = [[[first cg_splitView] subviews] objectAtIndex:0];
		NSView *contentPane = [[[first cg_splitView] subviews] objectAtIndex:1];
		CGFloat sidebarWidth = [sidebarPane frame].size.width;
		CGFloat contentWidthAt900 = [contentPane frame].size.width;
		CGFloat contentWidthAt700;

		check(![[first cg_pathControl] translatesAutoresizingMaskIntoConstraints]
		      && ![[first cg_splitView] translatesAutoresizingMaskIntoConstraints]
		      && ![[first cg_statusField] translatesAutoresizingMaskIntoConstraints],
		      "the three strips are placed by constraints, not by their masks");

		[[first window] setContentSize:NSMakeSize(700.0, 400.0)];
		check(near([[first cg_pathControl] frame].origin.y, 376.0)
		      && near([[first cg_pathControl] frame].size.height, 24.0),
		      "the path bar is the content's top strip");
		check(near([[first cg_statusField] frame].origin.y, 0.0)
		      && near([[first cg_statusField] frame].size.height, 22.0),
		      "the status bar is its bottom strip");
		check(near([[first cg_splitView] frame].origin.y, 22.0)
		      && near([[first cg_splitView] frame].size.height, 354.0),
		      "and the split view fills what is between");
		check(near([sidebarPane frame].size.width, sidebarWidth),
		      "the sidebar keeps its width when the window shrinks");
		contentWidthAt700 = [contentPane frame].size.width;
		check(contentWidthAt700 < contentWidthAt900, "while the content pane gives up the width");
		check(near([[first cg_iconView] frame].size.width,
			   [[[first cg_iconView] superview] frame].size.width),
		      "the icon view follows the clip view's width");

		[[first window] setContentSize:NSMakeSize(1000.0, 500.0)];
		check(near([[first cg_pathControl] frame].origin.y, 476.0)
		      && near([[first cg_splitView] frame].origin.y, 22.0)
		      && near([[first cg_splitView] frame].size.height, 454.0),
		      "a second, larger resize places the strips again");
		check(near([sidebarPane frame].size.width, sidebarWidth),
		      "the sidebar is still the width it was");
		check([contentPane frame].size.width > contentWidthAt700,
		      "and the content pane takes the added width");
	}

	/* A SECOND WINDOW IS A SECOND MODEL AND A SECOND HISTORY. */
	check(makeFile([subTwo stringByAppendingPathComponent:@"d.txt"]), "the second folder has a file");
	second = [[WSFileWindowController alloc] initWithDirectory:subTwo];
	check(second != nil && [second window] != [first window], "a second controller is a second window");
	check([second itemCount] == 1 && [[[second cg_statusField] stringValue] isEqual:@"1 item"],
	      "and it reports its own folder's count");
	check(![second canGoBack] && [first canGoBack],
	      "the two windows do not share a history cursor");
	check([[[[second cg_pathControl] URL] path] isEqual:subTwo], "nor a current folder");

	[backItem release];
	[listItem release];
	[columnItem release];
	[second close];
	[second release];
	[first close];
	[first release];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];

	printf("file_window: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
