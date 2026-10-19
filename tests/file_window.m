/*
 * file_window — the W2 shell: one folder, one model, and every strip reading it.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed.
 * SPDX-License-Identifier: MIT
 *
 * **WHAT THIS PROVES IS THE SHELL'S ONE RULE: the title, the path bar, the status bar and the icon view are four
 * renderings of ONE `WSItemModel`.** A navigation replaces that model and every strip follows; the history's
 * Back/Forward is the only thing that decides which folder is shown; and a second controller is a second folder
 * with its own model and its own cursor. Offscreen: no compositor, no click, no menu tracking.
 */
#import "WSFileIconView.h"
#import "WSFileWindowController.h"
#import "WSItemModel.h"
#import "WSPlaces.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSOutlineView.h>
#import <AppKit/NSPathControl.h>
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
	check([[first cg_viewSwitcher] segmentCount] == 4, "the switcher has four segments");
	check([[first cg_viewSwitcher] selectedSegment] == 0, "with Icon selected");
	check([[first cg_viewSwitcher] isEnabledForSegment:0]
	      && ![[first cg_viewSwitcher] isEnabledForSegment:1]
	      && ![[first cg_viewSwitcher] isEnabledForSegment:2]
	      && ![[first cg_viewSwitcher] isEnabledForSegment:3],
	      "and only Icon is enabled: List, Column and Cover Flow are later stages");
	check([[[first window] toolbar] items] != nil && [[[[first window] toolbar] items] count] >= 4,
	      "the toolbar has its items");
	check(![first canGoBack] && ![first canGoForward], "a new window has nowhere to go back or forward to");

	outline = [first cg_sidebarOutline];
	check([outline numberOfRows] == 6, "the sidebar expands two sections and their four places");
	check([first outlineView:outline numberOfChildrenOfItem:nil] == 2, "the sidebar has two sections");
	check([placeTitleAt(first, 0, 0) isEqual:@"Desktop"]
	      && [placeTitleAt(first, 0, 1) isEqual:@"Home"]
	      && [placeTitleAt(first, 0, 2) isEqual:@"Applications"],
	      "PLACES is Desktop, Home and Applications");
	check([placeTitleAt(first, 1, 0) isEqual:@"Computer"], "and DEVICES is Computer");

	backItem = [[NSMenuItem alloc] initWithTitle:@"Back" action:@selector(goBack:) keyEquivalent:@""];
	listItem = [[NSMenuItem alloc] initWithTitle:@"as List" action:@selector(cg_useListView:) keyEquivalent:@""];
	check(![first validateMenuItem:backItem], "Back is disabled at the first location");
	check(![first validateMenuItem:listItem], "and List is disabled: W2 has only Icon");

	/* **A DOUBLE-CLICK ON A FOLDER IS A NAVIGATION.** The first icon is at the grid's first cell; the event is
	 * converted through the view so the scroll view's own placement cannot change the answer. */
	{
		WSFileIconView *icons = [first cg_iconView];
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

	/* A WINDOW IS A SHELL, SO IT RESIZES. The strips keep their order: path bar at the top, status at the bottom,
	 * the split view between them, and the icon view inside its scroll view. */
	[[[first window] contentView] setFrameSize:NSMakeSize(700.0, 400.0)];
	check(near([[first cg_pathControl] frame].origin.y, 376.0)
	      && near([[first cg_pathControl] frame].size.height, 24.0),
	      "the path bar is the content's top strip");
	check(near([[first cg_statusField] frame].origin.y, 0.0)
	      && near([[first cg_statusField] frame].size.height, 22.0),
	      "the status bar is its bottom strip");
	check(near([[first cg_splitView] frame].origin.y, 22.0)
	      && near([[first cg_splitView] frame].size.height, 354.0),
	      "and the split view fills what is between");
	check([[first cg_iconView] frame].size.width > 0.0, "the icon view keeps a width after the resize");

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
	[second close];
	[second release];
	[first close];
	[first release];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];

	printf("file_window: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
