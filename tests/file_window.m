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
#import "WSContextMenu.h"
#import "WSFileOperations.h"
#import "WSIconView.h"
#import "WSFileWindowController.h"

/* **THE WINDOW'S OWN RE-READ AND ITS DOUBLE CLICK**, both declared here because the views are their only other callers. */
@interface WSFileWindowController (AGProbe)
- (void)refresh;
@end

/* **THE DOUBLE CLICK'S DOOR, DECLARED HERE BECAUSE IT IS THE WINDOW'S OWN.** The views call it
 * (`-listView:openItem:` and the grid's twin) and it is what a double click reaches; a probe sends it directly rather
 * than pretending to be a mouse. */
@interface WSFileWindowController (AGOpenProbe)
- (void)openItem:(WSItem *)item;
@end

#import <AppKit/NSSearchField.h>
#import "WSHairlineView.h"
#import "WSItemKind.h"
#import "WSItemModel.h"
#import "WSListView.h"
#import "WSPlaces.h"
#import "WSTrash.h"

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
#include <stdlib.h>
#include <sys/stat.h>
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

/* THE LAUNCH IS A PROCESS, SO THE PROOF IS A FILE: a bundle's executable writes its sentinel when it runs, and this
 * waits for it rather than assuming a spawn has been scheduled by the time `-openItem:` returns. */
static BOOL waitForFile(NSString *path, int milliseconds)
{
	int waited = 0;

	while (waited < milliseconds) {
		if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
			return YES;
		}
		usleep(20 * 1000);
		waited += 20;
	}
	return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static NSString *placeTitleAt(WSFileWindowController *controller, NSInteger section, NSInteger child)
{
	NSOutlineView *outline = [controller cg_sidebarOutline];
	id root = [controller outlineView:outline child:section ofItem:nil];
	id item = [controller outlineView:outline child:child ofItem:root];

	return [(WSPlace *)item title];
}

/* THE BAND'S OWN HIT-TEST, which a probe may ask: the only way to say WHERE an item is without publishing the layout. */
@interface NSObject (AGToolbarProbe)
- (NSInteger)indexAtPoint:(NSPoint)point;
@end

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
	/* **THE DEFAULTS STORE IS A FILE, AND THIS PROBE NOW READS A PREFERENCE OUT OF IT.** It gets one of its own, created
	 * before anything asks — so the check that a window "nobody has chosen for" shows its words is about a FRESH store
	 * rather than about whatever this machine, or a previous run of this probe, happened to leave in the real one. */
	{
		/* **AND OUTSIDE THE FIXTURE.** The store is a directory of files, and a window that writes a preference during its
		 * life would put one INSIDE the folder this probe counts — MEASURED, a sidebar width saved on a resize made the
		 * fixture hold five items where it holds four. */
		NSString *config = [@"/tmp" stringByAppendingPathComponent:
			[NSString stringWithFormat:@"agora-file-window-config-%d", (int)getpid()]];

		[[NSFileManager defaultManager] removeItemAtPath:config error:NULL];
		[[NSFileManager defaultManager] createDirectoryAtPath:config withIntermediateDirectories:YES
							   attributes:nil error:NULL];
		setenv("AGORA_CONFIG_ROOT", [config UTF8String], 1);
	}
	[application finishLaunching];

	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	check(makeDirectory(root), "the probe made its temporary tree");
	makeDirectory(folderA);
	makeDirectory(subOne);
	makeDirectory(subTwo);
	makeFile([root stringByAppendingPathComponent:@"b.txt"]);
	makeFile([root stringByAppendingPathComponent:@".hidden"]);
	makeFile([subOne stringByAppendingPathComponent:@"c.txt"]);
	/* **AND A TRASH, MADE HERE RATHER THAN FOUND.** `~/.Trash` is the real one and a probe has no business emptying it; a
	 * directory NAMED like one is what the rule reads, so the fixture is a `.Trash` of its own. */
	makeDirectory([root stringByAppendingPathComponent:@".Trash"]);

	first = [[WSFileWindowController alloc] initWithDirectory:root];
	check(first != nil && [first window] != nil, "a directory makes a window");
	check([[first directory] isEqual:root], "and the controller holds the folder it was given");
	check([first itemCount] == 4, "the model counts the two folders and one file, and not the hidden one");
	check([[[first cg_statusField] stringValue] isEqual:@"4 items"], "the status bar reports the model's count");
	check([[[[first cg_pathControl] URL] path] isEqual:root], "the path bar holds the same folder");
	check([[[first window] title] isEqual:[root lastPathComponent]],
	      "the title is the folder's own name");
	{
		/* **AND THE SEARCH FIELD IS IN THE TOOLBAR AND FILTERS THE MODEL.** Typing is the field's own business; what is
		 * measured here is the half this window owns — the query reaching `WSItemModel` and everything that reads the
		 * model hearing the answer. The status bar is the witness a person sees, and it reads the model's count. */
		NSSearchField *search = [first cg_searchField];

		check(search != nil, "the toolbar has a search field");
		[search setStringValue:@"b.t"];
		[application sendAction:[search action] to:[search target] from:search];
		check([first itemCount] == 1, "typing a name narrows the folder to the items whose names contain it");
		check([[[first cg_statusField] stringValue] isEqual:@"1 item"],
		      "and the status bar counts what the folder now shows");
		[search setStringValue:@""];
		[application sendAction:[search action] to:[search target] from:search];
		check([first itemCount] == 4 && [[[first cg_statusField] stringValue] isEqual:@"4 items"],
		      "and emptying the field gives the whole folder back");
	}
	{
		/* **THE TRASH IS A PLACE AND NOT A PATH.** A window on it says `Trash` and its path bar shows nothing: where the
		 * directory sits is the file manager's business, and `.Trash` under somebody's home says nothing true. */
		NSString *trash = [root stringByAppendingPathComponent:@".Trash"];
		WSFileWindowController *inTrash = [[WSFileWindowController alloc] initWithDirectory:trash];

		check([[[inTrash window] title] isEqual:@"Trash"],
		      "a window on the trash is titled Trash rather than the directory's own name");
		check([[inTrash cg_pathControl] URL] == nil, "and its path bar shows no path at all");
		check([[inTrash cg_pathControl] superview] == nil, "and it is not in the window's layout at all");

		/* **AND LEAVING THE TRASH PUTS BOTH BACK.** The title and the path bar are decided by WHERE the window is, not by
		 * where it started: a window opened on `.Trash` and sent Home must say the folder's name and show its breadcrumb
		 * again. The path bar is not merely hidden — it is not part of the layout — so the strip is re-installed rather
		 * than a flag flipped. */
		[inTrash navigateToDirectory:root];
		check([[[inTrash window] title] isEqual:[root lastPathComponent]],
		      "navigating out of the trash restores the folder's own title");
		check([[inTrash cg_pathControl] superview] != nil
		      && [[[inTrash cg_pathControl] URL] path] != nil,
		      "and the path bar is back, showing where the window now is");
		(void)inTrash;	/* the probe leaks it: the application owns its windows */
	}
	/* **THE TRASH'S MENU HAS THE WAY BACK, AND NOTHING ELSE DOES.** Every surface raises the same rows and aims them at
	 * whoever owns the selection; the window knows whether it is showing the Trash, and that is the one fact that turns
	 * "Move to Trash" into "Put Back". The put-back itself is the record beside each trashed item — the original path —
	 * so the probe gives the window a trash of its own rather than touching the account's. */
	{
		/* **A FIXTURE OF ITS OWN, OUTSIDE THE FOLDER THE REST OF THE PROBE IS LOOKING AT** — the window watches its
		 * directory, so a folder made inside it would change the count a later check reads. */
		NSString *fixture = [NSString stringWithFormat:@"%@-trash", root];
		NSString *tempTrash = [fixture stringByAppendingPathComponent:@".Trash"];
		NSString *doomed = [fixture stringByAppendingPathComponent:@"put-me-back.txt"];
		WSTrash *trash = [[WSTrash alloc] initWithRoot:tempTrash];
		WSFileOperations *operations = [[WSFileOperations alloc] initWithUndoManager:nil trash:trash];
		WSFileWindowController *inTrash;
		NSMenuItem *row;
		NSMenu *menu;

		check(makeDirectory(fixture), "a fixture is made");
		check(makeFile(doomed), "a file is made to be thrown away");
		check([[operations movePathsToTrash:[NSArray arrayWithObject:doomed] error:NULL] count] == 1,
		      "and goes into the probe's own trash, with its Put Back record");
		inTrash = [[WSFileWindowController alloc] initWithDirectory:tempTrash];
		[inTrash setFileOperations:operations];
		check([inTrash isTrashDirectory], "a window on a trash directory says so");

		menu = [WSContextMenu menuForSingleItemWithTarget:inTrash];
		check([[menu itemArray] count] > 0
		      && [[[[menu itemArray] objectAtIndex:0] title] isEqual:@"Put Back"]
		      && [[[menu itemArray] objectAtIndex:0] action] == @selector(putBack:),
		      "the trash's item menu begins with Put Back");
		check([menu indexOfItemWithTitle:@"Move to Trash"] == (NSInteger)NSNotFound,
		      "and offers no Move to Trash: an item in the bin has a way back, not further in");
		check([[WSContextMenu menuForMultipleItemsWithTarget:inTrash] indexOfItemWithTitle:@"Put Back"]
		      != (NSInteger)NSNotFound,
		      "a group of trashed items can go back together");
		check([[WSContextMenu menuForSingleItemWithTarget:first] indexOfItemWithTitle:@"Put Back"]
		      == (NSInteger)NSNotFound,
		      "while an ordinary folder's menu has no way back, because nothing is in a bin");

		/* **AND AN ITEM WITH NO RECORD GREYS THE ROW.** Something another program put in the bin has no original path
		 * to go back to, so the command would do nothing — the menu bar's own convention is that such a row is drawn
		 * grey rather than offered. */
		{
			NSString *stray = [tempTrash stringByAppendingPathComponent:@"no-record.txt"];
			NSMenuItem *grey = [[NSMenuItem alloc] initWithTitle:@"Put Back" action:@selector(putBack:)
							       keyEquivalent:@""];
			NSArray *items;
			NSInteger index;

			check(makeFile(stray), "a file is put in the trash with no record beside it");
			[inTrash refresh];
			items = [[[inTrash cg_iconView] model] items];
			for (index = 0; index < (NSInteger)[items count]; index++) {
				if ([[[items objectAtIndex:(NSUInteger)index] name] isEqual:@"no-record.txt"]) {
					[[inTrash cg_iconView] selectIndex:index];
				}
			}
			check([[[[inTrash selectedItems] lastObject] name] isEqual:@"no-record.txt"],
			      "the recordless item is the one selected");
			check(![inTrash validateMenuItem:grey],
			      "and Put Back is grey for it: there is nowhere to send it");
			[grey release];
			[[NSFileManager defaultManager] removeItemAtPath:stray error:NULL];
			[inTrash refresh];
		}

		/* **AND THE GRID, WHICH RAISES ITS OWN MENU.** The icon view answers Cut, Copy, Rename and Move to Trash itself,
		 * so its menu is aimed at the VIEW rather than at the window — and a view that cannot say it is showing the trash
		 * offered an ordinary folder's rows in the bin. It says so now, and the command is forwarded to the window that
		 * holds the records. ICON MODE IS WHERE THIS WAS MISSING; the list and the browser already reached the window. */
		{
			WSIconView *grid = [inTrash cg_iconView];
			NSRect cell = [grid cg_highlightRectAtIndex:0];
			NSEvent *right = [NSEvent mouseEventWithType:NSRightMouseDown
							    location:[grid convertPoint:NSMakePoint(NSMidX(cell),
												    NSMidY(cell))
										toView:nil]
						       modifierFlags:0 timestamp:0.0
							windowNumber:[[inTrash window] windowNumber]
							     context:nil eventNumber:0 clickCount:1 pressure:1.0f];
			NSMenu *iconMenu = [grid menuForEvent:right];

			check([grid isTrashDirectory], "the grid says it is showing the trash");
			check([[iconMenu itemArray] count] > 0
			      && [[[[iconMenu itemArray] objectAtIndex:0] title] isEqual:@"Put Back"]
			      && [[[iconMenu itemArray] objectAtIndex:0] target] == grid,
			      "so its own menu begins with Put Back, aimed at the grid");
			check([iconMenu indexOfItemWithTitle:@"Move to Trash"] == (NSInteger)NSNotFound,
			      "and offers no Move to Trash there either");
		}

		/* AND THE COMMAND ITSELF PUTS IT WHERE IT CAME FROM — through the GRID's row, which forwards it. */
		[[inTrash cg_iconView] selectIndex:0];
		row = [[NSMenuItem alloc] initWithTitle:@"Put Back" action:@selector(putBack:) keyEquivalent:@""];
		check([inTrash validateMenuItem:row], "the window answers the row while it is showing the trash");
		check(![first validateMenuItem:row], "and refuses it everywhere else");
		[row release];
		/* **AND THE COMMAND ITSELF RUNS THROUGH THE MENU ROW**, which is the dispatch a click takes: the row's target
		 * and action, not a call to the command. The grid's menu is aimed at the GRID, so this is also the proof that
		 * the grid forwards Put Back to the window that holds the records. */
		{
			NSRect cell = [[inTrash cg_iconView] cg_highlightRectAtIndex:0];
			NSEvent *right = [NSEvent mouseEventWithType:NSRightMouseDown
							    location:[[inTrash cg_iconView]
									convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell))
									   toView:nil]
						       modifierFlags:0 timestamp:0.0
							windowNumber:[[inTrash window] windowNumber]
							     context:nil eventNumber:0 clickCount:1 pressure:1.0f];
			NSMenu *iconMenu = [[inTrash cg_iconView] menuForEvent:right];

			check([iconMenu performActionForItemAtIndex:0],
			      "the menu's first row dispatches: Put Back, through the grid, to the window");
		}
		check([[NSFileManager defaultManager] fileExistsAtPath:doomed],
		      "Put Back puts the file back where it came from");
		check([inTrash itemCount] == 0, "and the trash the window shows is empty again");

		[inTrash close];
		[inTrash release];
		[operations release];
		[trash release];
		[[NSFileManager defaultManager] removeItemAtPath:fixture error:NULL];
	}
	/* **THE WATCHES ARE THE ROWS THE WINDOW DRAWS.** The folder shown, and every folder expanded under it: a change in a
	 * subtree nobody opened cannot change a row that is on the glass, and a subtree that IS open must stay live. So
	 * expanding adds a path and collapsing drops it, and the folder the window shows is always in the list. */
	{
		[first navigateToDirectory:root];
		[first setViewMode:1];
		{
			WSListView *list = [first cg_listView];
			WSItem *folder = [list cg_itemForPath:folderA];
			NSArray *paths;

			check(folder != nil, "a folder in the list is a row to expand");
			paths = [[first cg_watcher] paths];
			check([paths containsObject:root] && ![paths containsObject:folderA],
			      "before expanding, the window watches the folder it shows and nothing under it");

			[list expandItem:folder];
			check([[[first cg_watcher] paths] containsObject:folderA],
			      "expanding a folder puts a watch on it too");

			[list collapseItem:folder];
			check(![[[first cg_watcher] paths] containsObject:folderA],
			      "and collapsing it takes the watch away again");
			check([[[first cg_watcher] paths] containsObject:root],
			      "while the folder the window is showing stays watched");
		}
		[first setViewMode:0];
	}

	/* **AND THE BROWSER WATCHES THE FOLDER EVERY COLUMN SHOWS.** A column several levels down is on the glass, so a
	 * change in its folder has to arrive without anything else refreshing the window — MEASURED as "column view is slow
	 * to notice changes in the filesystem", because only the window's own folder was watched. Selecting a row opens the
	 * column beside it, and that column's folder joins the watches just as an expanded list row does. */
	{
		[first navigateToDirectory:root];
		[first cg_useColumnView:nil];
		{
			WSColumnView *columns = [first cg_columnView];
			NSBrowser *browser = [columns cg_browser];
			NSArray *paths = [[first cg_watcher] paths];
			NSArray *visible = [columns cg_visibleDirectories];

			check([paths containsObject:root], "the browser watches the folder column zero shows");
			check(visible != nil && [visible count] >= 1 && [[visible objectAtIndex:0] isEqual:root],
			      "and it says that is the only folder it is showing");

			[browser selectRow:0 inColumn:0];
			/* **THE ANNOUNCEMENT WAITS ONE TURN OF THE RUN LOOP**, because the browser grows the column after its
			 * delegate answers; a window's event loop turns that turn before the person's next breath. */
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
			paths = [[first cg_watcher] paths];
			visible = [columns cg_visibleDirectories];
			printf("  (note: with column one open the browser watches %lu folder(s))\n",
			       (unsigned long)[paths count]);
			check([visible containsObject:folderA],
			      "selecting a folder makes the column beside it a folder on the glass");
			check([paths containsObject:folderA],
			      "so that column's folder is watched too, without anything refreshing the window");
			check([paths containsObject:root], "and the folder column zero shows stays watched");
		}
		[first cg_useIconView:nil];
	}

	/* **THE VIEW SWITCHER IS PINNED TO THE RIGHT OF THE WINDOW, AND THE SPACE BEFORE IT IS WHAT A RESIZE OPENS.** The
	 * toolbar's default identifiers put one flexible spacer between Forward and the switcher, so the switcher must end
	 * at the band's trailing edge, and stay there when the window grows. MEASURED through the band's own pointer door,
	 * which is the same one a click uses. */
	{
		NSWindow *fileWindow = [first window];
		NSToolbar *toolbar = [fileWindow toolbar];
		NSView *band = [toolbar cg_view];
		NSUInteger lastIndex = [[toolbar items] count] - 1;

		check(band != nil && [band frame].size.width > 0.0, "the toolbar's band has a width");
		[fileWindow setContentSize:NSMakeSize(1100.0, 500.0)];
		printf("  (note: after a resize the band is %g wide and the item at its right edge is %ld of %lu)\n",
		       (double)[band frame].size.width,
		       (long)[(id)band indexAtPoint:NSMakePoint([band frame].size.width - 9.0, 20.0)],
		       (unsigned long)[[toolbar items] count]);
		check(fabs([band frame].size.width - 1100.0) < 1.0, "the band follows the window's new width");
		check((NSUInteger)[(id)band indexAtPoint:NSMakePoint([band frame].size.width - 9.0, 20.0)] == lastIndex,
		      "and the view switcher is against the band's right edge, not left behind at the old width");
		/* THE WINDOW GOES BACK to the size the rest of this probe measures against. */
		[fileWindow setContentSize:NSMakeSize(900.0, 560.0)];
		check(fabs([band frame].size.width - 900.0) < 1.0,
		      "and shrinking it again brings the band and the switcher back with it");
	}

	check([first cg_iconView] != nil, "the icon view exists");
	check([[first cg_iconView] itemCount] == 4, "the icon view shows the model's items");
	{
		NSScrollView *content = [[first cg_iconView] enclosingScrollView];

		check([content autohidesScrollers] && [[content verticalScroller] isHidden],
		      "and the four icons fit, so the content pane's bar is hidden");
	}
	check([[first cg_viewSwitcher] segmentCount] == 3, "the switcher has three segments");
	check([[first cg_viewSwitcher] selectedSegment] == 0, "with Icon selected");
	/* **AND ITS THREE SEGMENTS ARE PICTURES, NOT WORDS.** A file window's views are a MODE, and three words in a band of
	 * verbs read as three commands; each segment wears the symbol of the view it selects, so the image is what the
	 * switch says and the toolbar ITEM's label under it is the one place a word belongs. The names are the theme's own
	 * (`toolbar:` asks the theme that holds the UI's symbols), so a missing one would be a blank chip rather than a
	 * wrong word — which is why the pictures are checked for. */
	check([[first cg_viewSwitcher] imageForSegment:0] != nil
	      && [[first cg_viewSwitcher] imageForSegment:1] != nil
	      && [[first cg_viewSwitcher] imageForSegment:2] != nil,
	      "each segment wears a picture of its view");
	check([[first cg_viewSwitcher] labelForSegment:0] == nil
	      && [[first cg_viewSwitcher] labelForSegment:1] == nil
	      && [[first cg_viewSwitcher] labelForSegment:2] == nil,
	      "and no segment carries a word");
	check([[first cg_viewSwitcher] isEnabledForSegment:0]
	      && [[first cg_viewSwitcher] isEnabledForSegment:1]
	      && [[first cg_viewSwitcher] isEnabledForSegment:2],
	      "all three views are enabled");
	check([[[first window] toolbar] items] != nil && [[[[first window] toolbar] items] count] >= 4,
	      "the toolbar has its items");

	check(![first canGoBack] && ![first canGoForward], "a new window has nowhere to go back or forward to");

	outline = [first cg_sidebarOutline];
	check([first cg_splitView].dividerStyle == NSSplitViewDividerStylePaneSplitter
	      && [[first cg_splitView] dividerThickness] == 12.0,
	      "the sidebar's divider is the split view's twelve-point gutter");
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

		/* **AN ARCHIVE IS MADE BESIDE THE THING IT WAS MADE FROM.** Compress used to write into
		 * `-cg_commandDirectory`, which answers the COLUMN a context menu was raised in and is the browser's ROOT when
		 * the command comes from the menu bar — MEASURED in a session, compressing `Applications/Forge.app` from the
		 * File menu put `Forge.zip` in the home folder, one column to the left of the thing it was made from. The rule
		 * is the SELECTION's own folder, and that is what this asks for. */
		{
			NSString *archive = [root stringByAppendingPathComponent:
				[[subTwo lastPathComponent] stringByAppendingPathExtension:@"zip"]];

			[first cg_useIconView:nil];
			[[first cg_iconView] cg_selectPaths:[NSArray arrayWithObject:subTwo]];
			check([[[first cg_iconView] selectedItems] count] == 1,
			      "a folder is selected in the icon view");
			check([[first cg_destinationBesideSelection] isEqual:root],
			      "and the destination is the folder that holds it");
			/* **AND IT ARRIVES THROUGH THE RIGHT-CLICK MENU'S LEAF, NOT ONLY THROUGH THE MENU BAR.** The leaf the
			 * pointer raises names `-compress:` with the format as its tag, and sending it is what a click does. */
			{
				NSMenu *menu = [WSContextMenu menuForSingleItemWithTarget:first];
				NSMenu *compression = (NSMenu *)[[menu itemAtIndex:[menu indexOfItemWithTitle:@"Compression"]] submenu];
				NSMenuItem *row = (compression != nil)
					? [compression itemAtIndex:(NSInteger)WSArchiveFormatZip] : nil;

				check(row != nil && [row action] == @selector(compress:)
				      && [row tag] == (NSInteger)WSArchiveFormatZip,
				      "the context menu carries a Zip leaf aimed at the window");
				[NSApp sendAction:[row action] to:[row target] from:row];
			}
			check([[NSFileManager defaultManager] fileExistsAtPath:archive],
			      "Compress puts the archive beside the selected item");
			[[NSFileManager defaultManager] removeItemAtPath:archive error:NULL];
		}

	/* **A COMMAND RAISED IN A COLUMN ACTS ON THAT COLUMN'S FOLDER.** The window owns New Folder and Paste, so it has to
	 * be told which folder the menu was raised in: MEASURED as "new directory in the third column currently creates a new
	 * directory in the first". Here the second column lists an empty folder, and a right-click in it must put the folder
	 * THERE — and the column view must show it without the window being reopened. */
	{
		WSColumnView *columns;
		NSBrowser *browser;
		NSArray *inside;

		[first cg_useColumnView:nil];
		columns = [first cg_columnView];
		browser = [columns cg_browser];

		/* **THE CRUMBS FOLLOW THE RIGHTMOST COLUMN.** A browser shows a chain of folders at once, and the one a person has
		 * walked into is the one on the right: the window holds the folder it opened on, but what it SAYS it is showing has
		 * to be the deepest column's. MEASURED before this: the path bar read the leftmost column however deep the columns
		 * went, which is the one thing a breadcrumb is for. A click is a selection AND the action the browser sends after
		 * it (`-doClick:`, which is what `NSBrowser`'s own button path does), and the announcement that follows is one
		 * run-loop turn later, because the browser grows the column after its delegate answers. */
		[first navigateToDirectory:root];	/* the crumbs start where the window is */
		{
			NSRunLoop *loop = [NSRunLoop currentRunLoop];

			[browser selectRow:0 inColumn:0];
			[browser doClick:nil];
			[loop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
			check([[[first cg_pathControl] URL] path] != nil
			      && [[[[first cg_pathControl] URL] path] isEqual:folderA],
			      "selecting a folder in a column makes the crumbs show THAT folder");
			check([[[first window] title] isEqual:[folderA lastPathComponent]],
			      "and the title follows with it");
			check([[first directory] isEqual:root],
			      "while the window itself still holds the folder it opened on");

			[browser selectRow:-1 inColumn:0];
			[browser doClick:nil];
			[loop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
			check([[[[first cg_pathControl] URL] path] isEqual:root],
			      "and deselecting it puts the crumbs back where the window is");
			[browser selectRow:0 inColumn:0];
			[browser doClick:nil];
			[loop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		}
		check([browser numberOfRowsInColumn:1] == 0, "the folder selected in column zero is empty, so column one is too");
		{
			NSRect strip = [browser titleFrameOfColumn:1];
			NSPoint inWindow = [browser convertPoint:NSMakePoint(NSMidX(strip), NSMidY(strip)) toView:nil];
			NSEvent *event = [NSEvent mouseEventWithType:NSRightMouseDown location:inWindow
				modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil eventNumber:0
				clickCount:1 pressure:1.0f];

			check([browser menuForEvent:event] != nil,
			      "a right-click in the second column raises the folder's own menu");
		}
		check([[columns cg_commandDirectory] isEqual:folderA],
		      "and the folder it is about is the one that column lists");
		[first newFolder:nil];
		inside = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folderA error:NULL];
		printf("  (note: after New Folder in column one, that folder holds %lu item(s))\n",
		       (unsigned long)[inside count]);
		check([inside count] == 1, "New Folder makes the folder in the COLUMN's folder, not in the window's");
		check([browser numberOfRowsInColumn:1] == 1, "and the column view shows it at once");
		/* THE FIXTURE GOES BACK AS IT WAS: later checks in this probe count what A Folder holds. */
		{
			NSUInteger k;

			for (k = 0; k < [inside count]; k++) {
				[[NSFileManager defaultManager] removeItemAtPath:
					[folderA stringByAppendingPathComponent:[inside objectAtIndex:k]] error:NULL];
			}
		}
		[first cg_useIconView:nil];
	}

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
		CGFloat expectedSecond = [browser widthOfColumn:0] + 12.0;

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

	/* **AND A COMMAND THE GRID ITSELF PERFORMED ENDS WHERE THE MENU'S DOES.** The icon view was handed THIS window's
	 * operation manager (its progress handler owns the plate), so a grid command that ends by refreshing the window alone
	 * leaves that plate on the glass — MEASURED, as a half-transparent rounded panel hanging in the middle of the window
	 * after New Folder with Selection. The plate is a real window with a real visibility flag here, so this is a
	 * measurement of the ending and not of the compositor. */
	{
		WSIconView *icons = [first cg_iconView];
		NSInteger before = [first itemCount];

		/* **THE WINDOW OWNS THE ENDING, AND THIS IS THE DOOR THE GRID HAS TO KNOCK ON.** A plate's visibility is a
		 * compositor's answer and this probe has none — MEASURED: the same check passed with the bug in place — so what is
		 * asserted here is the CONTRACT (`-iconViewDidFinishOperation:` exists and this window answers it) and the
		 * operation's real effect. The grid's own suite counts the call. */
		check([first respondsToSelector:@selector(iconViewDidFinishOperation:)],
		      "the window answers the grid's \"the operation is over\" door, which is what closes the progress plate");
		[icons newFolder:nil];
		check([first itemCount] == before + 1, "New Folder from the grid adds the folder the way the menu's row does");
		[first undo:nil];
		check([first itemCount] == before, "whose Undo still works, because the manager is the window's");
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
		/* **AND THE SPLIT VIEW ENDS ONE POINT ABOVE THE STATUS BAR, WHERE THE RULE IS.** The strip is a bare
		 * label with no border, so the pane above it met the window's face with nothing between them; the
		 * hairline is a view of its own, pinned to the same edges. */
		check(near([[first cg_splitView] frame].origin.y, 23.0)
		      && near([[first cg_splitView] frame].size.height, 353.0),
		      "and the split view fills what is between, less the hairline above the status bar");
		{
			WSHairlineView *rule = nil;
			NSArray *subs = [[[first window] contentView] subviews];
			NSUInteger i;

			for (i = 0; i < [subs count]; i++) {
				NSView *v = [subs objectAtIndex:i];

				if ([v isKindOfClass:[WSHairlineView class]]) {
					rule = (WSHairlineView *)v;
				}
			}
			check(rule != nil, "the status bar's hairline is in the content view");
			if (rule != nil) {
				/* **ITS PLACE IS WHAT CAN SILENTLY BREAK** — a rule that is not pinned above the status bar is a
				 * grey line in the wrong place, and one that is not one point tall is a band. The colour is
				 * `controlDarkShadowColor`, the same tier grey the splitter's hairlines and a column's title rule use,
				 * and `libagora-app/tests/split_view.m` measures that grey in pixels. */
				check([rule isOpaque], "and it is opaque, so it cannot be skipped as transparent");
				check(near([rule frame].origin.y, 22.0) && near([rule frame].size.height, 1.0)
				      && near([rule frame].size.width, 700.0),
				      "it is one point tall, as wide as the window and directly above the status bar");
			}
		}
		check(near([sidebarPane frame].size.width, sidebarWidth),
		      "the sidebar keeps its width when the window shrinks");
		contentWidthAt700 = [contentPane frame].size.width;
		check(contentWidthAt700 < contentWidthAt900, "while the content pane gives up the width");
		check(near([[first cg_iconView] frame].size.width,
			   [[[first cg_iconView] superview] frame].size.width),
		      "the icon view follows the clip view's width");

		[[first window] setContentSize:NSMakeSize(1000.0, 500.0)];
		check(near([[first cg_pathControl] frame].origin.y, 476.0)
		      && near([[first cg_splitView] frame].origin.y, 23.0)
		      && near([[first cg_splitView] frame].size.height, 453.0),
		      "a second, larger resize places the strips again, the hairline above the status bar included");
		check(near([sidebarPane frame].size.width, sidebarWidth),
		      "the sidebar is still the width it was");
		check([contentPane frame].size.width > contentWidthAt700,
		      "and the content pane takes the added width");
	}

	/* **AN APPLICATION BUNDLE IS A PACKAGE, AND DOUBLE-CLICKING IT RUNS IT.** The bundle's `Contents` is a directory
	 * like any other, so `-isDirectory` alone cannot tell a person's application from a folder to browse — the item
	 * asks the AppKit whether the directory is a PACKAGE, and every open and every disclosure tree reads that one
	 * answer. The fixture is a real bundle whose executable is a script, so "it ran" is a file on disk. */
	{
		NSString *bundleRoot = [root stringByAppendingPathComponent:@"Applications"];
		NSString *bundle = [bundleRoot stringByAppendingPathComponent:@"Probe.app"];
		NSString *contents = [bundle stringByAppendingPathComponent:@"Contents"];
		NSString *macos = [contents stringByAppendingPathComponent:@"MacOS"];
		NSString *probe = [macos stringByAppendingPathComponent:@"Probe"];
		NSString *marker = [root stringByAppendingPathComponent:@"probe-ran.txt"];
		NSString *manifest = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
			"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
			"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
			"<plist version=\"1.0\"><dict>\n"
			"<key>CFBundleIdentifier</key><string>com.agora.file-window-probe</string>\n"
			"<key>CFBundleExecutable</key><string>Probe</string>\n"
			"<key>CFBundlePackageType</key><string>APPL</string>\n"
			"</dict></plist>\n";
		WSItem *bundleItem;
		WSItem *folderItem = [[[WSItem alloc] initWithName:@"A Folder" path:folderA isDirectory:YES] autorelease];
		WSFileWindowController *applications;
		NSString *kind;

		check(makeDirectory(macos)
		      && [manifest writeToFile:[contents stringByAppendingPathComponent:@"Info.plist"]
				     atomically:YES encoding:NSUTF8StringEncoding error:NULL]
		      && [@"#!/bin/sh\nprintf ran > \"$AGORA_PROBE_OUT\"\n" writeToFile:probe
										     atomically:YES
										       encoding:NSUTF8StringEncoding error:NULL]
		      && chmod([probe UTF8String], 0755) == 0,
		      "the probe built an application bundle with a runnable executable");

		bundleItem = [[[WSItem alloc] initWithName:@"Probe.app" path:bundle isDirectory:YES] autorelease];
		check([bundleItem isDirectory], "an application bundle is a directory on disk");
		check([bundleItem isPackage], "and the AppKit says it is a package");
		check(![folderItem isPackage] && [folderItem isBrowsable],
		      "a plain folder is not a package, and is browsable");
		check(![bundleItem isBrowsable], "while a bundle is not something to browse into");
		kind = [WSItemKind kindForItem:bundleItem];
		check(kind != nil
		      && [[kind lowercaseString] rangeOfString:@"application"].location != NSNotFound,
		      "and its Kind is Launch Services', not \"Folder\"");

		applications = [[WSFileWindowController alloc] initWithDirectory:bundleRoot];
		check([applications itemCount] == 1, "the Applications folder lists the bundle");
		setenv("AGORA_PROBE_OUT", [marker UTF8String], 1);
		{
			WSIconView *icons = [applications cg_iconView];
			NSPoint inWindow = [icons convertPoint:NSMakePoint(30.0, 30.0) toView:nil];
			NSEvent *down = [NSEvent mouseEventWithType:NSLeftMouseDown location:inWindow
						       modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
						      eventNumber:0 clickCount:2 pressure:1.0f];

			[icons mouseDown:down];
		}
		check([[applications directory] isEqual:bundleRoot],
		      "double-clicking the bundle does not open its Contents");
		check(waitForFile(marker, 3000), "and the bundle's executable RAN instead");

		/* THE SAME ANSWER DECIDES THE TREE, so the bundle is a leaf in the two views that can expand one. */
		[applications cg_useListView:nil];
		{
			WSListView *list = [applications cg_listView];
			WSItem *row = [list cg_itemForPath:bundle];

			check(row != nil && ![list outlineView:list isItemExpandable:row],
			      "in List mode it is one row with no disclosure triangle");
		}
		[applications cg_useColumnView:nil];
		{
			WSColumnView *columns = [applications cg_columnView];
			NSBrowser *browser = [columns cg_browser];
			WSItem *previewed;

			[browser selectRow:0 inColumn:0];
			previewed = [columns cg_previewItem];
			check(previewed != nil && [[previewed name] isEqual:@"Probe.app"]
			      && [browser numberOfRowsInColumn:1] == 0,
			      "and in Column mode it previews, and opens no column of Contents");
		}

		[applications close];
		[applications release];
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

	/* **AND THE BAND'S WORDS ARE ONE PREFERENCE, WHICH THE VIEW MENU FLIPS.** A toolbar's labels are not a per-window
	 * choice: putting them away means the same thing in every file window, so the answer is remembered and applied, and
	 * the menu's tick is read back from it rather than remembered a second time.
	 *
	 * **IT RUNS LAST, ON A WINDOW OF ITS OWN, AND BOTH ARE DELIBERATE.** `NSToolbar -setDisplayMode:` changes the band's
	 * height and with it the window's frame, and a round trip through `IconOnly` back to `IconAndLabel` does not restore
	 * the frame EXACTLY — a known latent defect of `-setSizeMode:`, not of this preference. A window made for the
	 * measurement keeps that perturbation away from the thirteen checks above, which read the first window's layout. */
	{
		WSFileWindowController *banded = [[WSFileWindowController alloc] initWithDirectory:folderA];
		NSMenuItem *row = [[NSMenuItem alloc] initWithTitle:@"Show Toolbar Labels" action:NULL keyEquivalent:@""];

		check([WSFileWindowController cg_toolbarLabelsVisible],
		      "a window nobody has chosen for shows its toolbar's words");
		check([[[banded window] toolbar] displayMode] == NSToolbarDisplayModeIconAndLabel,
		      "and its band was built that way");

		[WSFileWindowController cg_setToolbarLabelsVisible:NO];
		check(![WSFileWindowController cg_toolbarLabelsVisible], "the preference can be put away");
		[banded cg_applyToolbarLabels];
		check([[[banded window] toolbar] displayMode] == NSToolbarDisplayModeIconOnly,
		      "and a window applies it to the band it already has");

		/* **AND THE BAND'S OWN ROW TICKS TOO, FROM THE WINDOW THAT OWNS THE BAND.** `Show Toolbar` sends
		 * `-toggleToolbarShown:`, which is `NSWindow`'s door, so the WINDOW is the row's target and the window is what
		 * validates it — the state is read from the band it owns, never remembered twice. A hidden band unticks the row and
		 * a shown one ticks it back, which is the pair a person sees in the menu. */
		{
			NSMenuItem *showRow = [[NSMenuItem alloc] initWithTitle:@"Show Toolbar"
									action:@selector(toggleToolbarShown:)
								 keyEquivalent:@"t"];

			check([[banded window] validateMenuItem:showRow] && [showRow state] == NSOnState,
			      "the window ticks \"Show Toolbar\" while the band shows");
			[[[banded window] toolbar] setVisible:NO];
			check([[banded window] validateMenuItem:showRow] && [showRow state] == NSOffState,
			      "and unticks it when the band is put away");
			[[[banded window] toolbar] setVisible:YES];
			check([[banded window] validateMenuItem:showRow] && [showRow state] == NSOnState,
			      "with the tick back when it is shown again");
			[showRow release];
		}

		[WSFileWindowController cg_showToolbarLabelsStateOn:row];
		check([row state] == NSOffState, "the menu's tick says the words are off");
		/* **AND A WINDOW MADE WHILE THE WORDS ARE AWAY IS BUILT WITHOUT THEM**, which is the half a window's own apply
		 * cannot cover: the preference is read when the band is BUILT, so a file window opened after the choice already
		 * agrees with it rather than waiting to be told. */
		{
			WSFileWindowController *later = [[WSFileWindowController alloc] initWithDirectory:folderA];

			check([[[later window] toolbar] displayMode] == NSToolbarDisplayModeIconOnly,
			      "a window opened while the words are away is born without them");
			[later close];
			[later release];
		}

		[WSFileWindowController cg_setToolbarLabelsVisible:YES];
		[WSFileWindowController cg_showToolbarLabelsStateOn:row];
		check([row state] == NSOnState, "and it follows the preference back on");
		[banded cg_applyToolbarLabels];
		check([[[banded window] toolbar] displayMode] == NSToolbarDisplayModeIconAndLabel,
		      "with the band following it back too");
		[row release];
		[banded close];
		[banded release];
	}

	/* **A FOLDER MADE BEHIND THE WINDOW'S BACK APPEARS IN IT.** The window read its directory once and nothing told it
	 * to read again, so a directory made in a terminal (or by another application) stayed invisible until a person
	 * navigated away and back — and its own New Folder did not appear either, because the refresh re-laid the views out
	 * over a model that had not been re-read. The kernel's change stream (`libagora-watch`) is what tells it now.
	 *
	 * **A WINDOW OF ITS OWN, IN LIST MODE, WHICH IS WHERE IT WAS REPORTED.** The one built above has already been in
	 * Column mode, and that view reloads the model itself — a check run in it would pass for that reason and say nothing
	 * about this window, which has never left the view the report was about. */
	{
		WSFileWindowController *watched = [[WSFileWindowController alloc] initWithDirectory:root];
		NSString *made = [root stringByAppendingPathComponent:@"Made Outside"];
		WSListView *list;
		NSInteger before;
		NSInteger attempt;
		BOOL listed = NO;

		[watched setViewMode:1];
		check([[watched directory] isEqual:root] && [watched cg_watcher] != nil,
		      "a window watches the folder it shows");
		before = [watched itemCount];
		check([[NSFileManager defaultManager] createDirectoryAtPath:made withIntermediateDirectories:YES
									 attributes:nil error:NULL],
		      "a directory is made behind the window's back");
		for (attempt = 0; attempt < 20 && [watched itemCount] == before; attempt++) {
			usleep(100000);
			[[watched cg_watcher] cg_drain];
		}
		check([watched itemCount] == before + 1,
		      "and the stream refreshes it: the new folder is in the model without navigating");
		list = [watched cg_listView];
		{
			NSInteger row;

			for (row = 0; row < [list numberOfRows]; row++) {
				if ([[(WSItem *)[list itemAtRow:row] name] isEqual:@"Made Outside"]) {
					listed = YES;
				}
			}
		}
		check(listed, "and List mode's rows carry it, which is the view the report was about");

		/* **AND THE WINDOW'S OWN NEW FOLDER APPEARS THE SAME WAY.** It always did the *file* operation; what it never
		 * did was re-read the directory afterwards. */
		before = [watched itemCount];
		[watched newFolder:nil];
		check([watched itemCount] == before + 1,
		      "a folder made by the window's own command is in the model at once");
		[watched close];
		[watched release];
	}

	/* **THE PLACES PANE AND THE COLUMNS KEEP THE WIDTHS A PERSON DRAGGED.** Two stores, one idea: a width that a drag
	 * changed and the next window forgot is a window that argues with its user. The pane's width is the window's own
	 * preference; a browser column's is `NSBrowser`'s autosave, which does nothing until it is given a name — MEASURED,
	 * a column dragged wider came back at 220 in the next window. */
	{
		WSFileWindowController *third;
		WSColumnView *columns;
		CGFloat paneWidth;

		[WSFileWindowController cg_setSidebarWidth:260.0];
		third = [[WSFileWindowController alloc] initWithDirectory:root];
		paneWidth = NSWidth([[[[third cg_splitView] subviews] objectAtIndex:0] frame]);
		printf("  (note: the places pane opens %.0f wide after 260 was remembered)\n", (double)paneWidth);
		check(near(paneWidth, 260.0), "a window opens with the places pane at the width last dragged");
		[third close];
		[third release];

		[first cg_useColumnView:nil];
		columns = [first cg_columnView];
		[[columns cg_browser] setWidth:300.0 ofColumn:0];
		check(near([[columns cg_browser] widthOfColumn:0], 300.0), "a column can be dragged wider");
		[first cg_useIconView:nil];
		{
			WSFileWindowController *fourth = [[WSFileWindowController alloc] initWithDirectory:root];

			[fourth cg_useColumnView:nil];
			printf("  (note: the next window's first column is %.0f wide)\n",
			       (double)[[[fourth cg_columnView] cg_browser] widthOfColumn:0]);
			check(near([[[fourth cg_columnView] cg_browser] widthOfColumn:0], 300.0),
			      "and the next window opens its first column at that width");
			[fourth close];
			[fourth release];
		}
		/* THE FIXTURE GOES BACK TO THE WIDTHS IT STARTED WITH, for the probes that measure them. */
		[WSFileWindowController cg_setSidebarWidth:220.0];
		[first cg_useColumnView:nil];
		[[[first cg_columnView] cg_browser] setWidth:220.0 ofColumn:0];
		[first cg_useIconView:nil];
	}

	/* **THE DEFAULT VIEW IS WHAT A NEW WINDOW OPENS IN.** The preference is a person's answer to "how do I browse", and
	 * the window reads it once, when it is made: MEASURED here through two windows, because a value read into a field
	 * that no build path consults would look identical to one that is honoured. The probe's defaults are its own
	 * (`AGORA_CONFIG_ROOT`), so the account's preferences are untouched. */
	{
		WSFileWindowController *third;

		[WSFileWindowController cg_setDefaultViewMode:2];
		third = [[WSFileWindowController alloc] initWithDirectory:root];
		check([third viewMode] == 2 && [third cg_columnView] != nil,
		      "a new window opens in the preferred view, with that view built");
		[third close];
		[third release];

		[WSFileWindowController cg_setDefaultViewMode:0];
		third = [[WSFileWindowController alloc] initWithDirectory:root];
		check([third viewMode] == 0 && [third cg_iconView] != nil,
		      "and back to Icon when the preference says Icon");
		[third close];
		[third release];
	}


	/* **AN ARCHIVE UNPACKS BESIDE ITSELF, FROM A DOUBLE CLICK AND FROM THE MENU ROW.** A window of its own, so the
	 * selection is this block's and not one left over from the column walk above. The row is asked for
	 * (`-cg_selectionCanBeExtracted`) and the double click takes the same command, which is why both are measured against
	 * the same archive: one extraction each, and the second gets "trip 2" because the first took "trip". */
	{
		NSString *trip = [root stringByAppendingPathComponent:@"trip"];
		NSString *archive;
		NSString *firstFolder = [root stringByAppendingPathComponent:@"trip"];
		NSString *secondFolder = [root stringByAppendingPathComponent:@"trip 2"];
		WSFileWindowController *fresh;
		WSItem *zipItem;

		[[NSFileManager defaultManager] createDirectoryAtPath:trip withIntermediateDirectories:YES
							   attributes:nil error:NULL];
		/* TWO FILES, because this block is about the FOLDER case: one file would take the single-file rule and land
		 * beside the archive as itself. */
		[[NSMutableData dataWithLength:64] writeToFile:[trip stringByAppendingPathComponent:@"inside.txt"]
						   atomically:NO];
		[[NSMutableData dataWithLength:64] writeToFile:[trip stringByAppendingPathComponent:@"other.txt"]
						   atomically:NO];
		fresh = [[WSFileWindowController alloc] initWithDirectory:root];
		archive = [[fresh fileOperations] compressPaths:[NSArray arrayWithObject:trip] inDirectory:root error:NULL];
		check(archive != nil, "an archive is made on the window's folder");
		/* THE SOURCE GOES, so the extraction's own name is free — and the window re-reads, because the archive was made
		 * by the manager and no view has heard about it. */
		[[NSFileManager defaultManager] removeItemAtPath:trip error:NULL];
		[fresh refresh];
		[fresh cg_useListView:nil];
		[[fresh cg_listView] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
		{
			/* THE ROW BY NAME, because the fixture root holds everything the earlier checks left in it and a row number
			 * would be a guess about the sort. */
			NSOutlineView *list = (NSOutlineView *)[fresh cg_listView];
			NSInteger row;

			for (row = 0; row < [list numberOfRows]; row++) {
				id item = [list itemAtRow:row];

				if ([[[item path] lastPathComponent] isEqual:[archive lastPathComponent]]) {
					[list selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
					  byExtendingSelection:NO];
					break;
				}
			}
			check(row < [list numberOfRows], "the archive is a row in the window");
		}
		check([fresh cg_selectionCanBeExtracted], "a selected archive says it can be extracted");
		{
			/* THE MENU THE LIST RAISES IS AIMED AT THE WINDOW, which is where the command lives. */
			NSMenu *menu = [WSContextMenu menuForSingleItemWithTarget:fresh];
			NSMenuItem *row = [menu itemAtIndex:[menu indexOfItemWithTitle:@"Extract Archive"]];

			check(row != nil && [row action] == @selector(extractArchive:) && [row target] == fresh,
			      "the right-click menu carries the row, aimed at the window");
			[NSApp sendAction:[row action] to:[row target] from:row];
		}
		check([[NSFileManager defaultManager] fileExistsAtPath:firstFolder],
		      "sending the row unpacks the archive into a folder named for it");
		check([[NSFileManager defaultManager]
			fileExistsAtPath:[firstFolder stringByAppendingPathComponent:@"trip/inside.txt"]],
		      "with the archive's own contents inside it");

		/* **AND THE FORMAT IS THE SUBMENU LEAF'S, NOT A SECOND COMMAND.** Sending the Tar.gz leaf beside the working
		 * "Extract Archive" row is what a person's click does; the tag is what carries the choice. */
		{
			NSString *tarred = [root stringByAppendingPathComponent:@"trip.tar.gz"];
			NSMenu *menu = [WSContextMenu menuForSingleItemWithTarget:fresh];
			NSMenu *compression = (NSMenu *)[[menu itemAtIndex:[menu indexOfItemWithTitle:@"Compression"]] submenu];
			NSMenuItem *leaf = [compression itemAtIndex:(NSInteger)WSArchiveFormatTarGzip];

			check(leaf != nil && [leaf tag] == (NSInteger)WSArchiveFormatTarGzip
			      && [leaf action] == @selector(compress:),
			      "the Compression submenu carries a leaf for each format, tagged with it");
			[NSApp sendAction:[leaf action] to:[leaf target] from:leaf];
			check([[NSFileManager defaultManager] fileExistsAtPath:tarred],
			      "and sending the Tar.gz leaf writes that archive beside the selection");
			[[NSFileManager defaultManager] removeItemAtPath:tarred error:NULL];
		}

		/* AND THE DOUBLE CLICK: the same command, through the door the views report to. */
		zipItem = [[WSItem alloc] initWithName:[archive lastPathComponent] path:archive isDirectory:NO];
		[fresh openItem:zipItem];
		[zipItem release];
		check([[NSFileManager defaultManager] fileExistsAtPath:secondFolder],
		      "and a double click unpacks it again, into \"trip 2\" because the first took \"trip\"");
		[fresh close];
		[fresh release];
	}

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
