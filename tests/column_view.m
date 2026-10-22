/*
 * column_view — W5: the browser's columns, the selection that opens the next one, and the preview.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE RELATIONSHIP IS THE TEST.** Column 0 is the folder; selecting a branch row must make column 1 its children,
 * and column 2 their children; selecting a leaf must add no column and put that item in the preview. The preview is
 * the rightmost part of the view and shows the selected item's name, Kind, size and date.
 */
#import "WSColumnView.h"
#import "WSItemKind.h"
#import "WSItemModel.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSBrowser.h>
#import <AppKit/NSBrowserCell.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTableColumn.h>
#import <AppKit/NSTableView.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <math.h>
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

static BOOL makeDirectory(NSString *path)
{
	return [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
								  attributes:nil error:NULL];
}

static BOOL makeFile(NSString *path, NSUInteger bytes)
{
	return [[NSFileManager defaultManager] createFileAtPath:path contents:[NSMutableData dataWithLength:bytes]
						      attributes:nil];
}

static NSString *cellAt(NSBrowser *browser, NSInteger row, NSInteger column)
{
	NSTableView *table = [browser cg_tableForColumn:column];
	NSCell *cell = [table preparedCellAtColumn:0 row:row];

	return [cell stringValue];
}

@interface AGColumnProbe : NSObject <WSColumnViewDelegate>
{
@public
	NSString *opened;
}
@end

@implementation AGColumnProbe
- (void)columnView:(WSColumnView *)view openItem:(WSItem *)item
{
	(void)view;
	[opened release];
	opened = [[item name] copy];
}
- (void)dealloc
{
	[opened release];
	[super dealloc];
}
@end

int main(void)
{
	NSApplication *application = [NSApplication sharedApplication];
	NSString *root = [@"/tmp" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-column-view-%d", (int)getpid()]];
	NSString *aFolder = [root stringByAppendingPathComponent:@"A Folder"];
	NSString *bFolder = [root stringByAppendingPathComponent:@"B Folder"];
	NSString *aChild = [aFolder stringByAppendingPathComponent:@"A Child"];
	WSItemModel *model;
	WSColumnView *view;
	NSWindow *window;
	AGColumnProbe *probe;

	setvbuf(stdout, NULL, _IONBF, 0);
	[application finishLaunching];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	check(makeDirectory(root), "the probe made its temporary tree");
	makeDirectory(aFolder);
	makeDirectory(bFolder);
	makeDirectory(aChild);
	makeFile([root stringByAppendingPathComponent:@"notes.txt"], 11);
	makeFile([aFolder stringByAppendingPathComponent:@"a.txt"], 5);
	makeFile([aChild stringByAppendingPathComponent:@"leaf.txt"], 7);

	model = [[WSItemModel alloc] initWithDirectory:root];
	view = [[WSColumnView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 800.0, 400.0) model:model];
	probe = [[AGColumnProbe alloc] init];
	[view setViewDelegate:probe];
	window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 800.0, 400.0)
					     styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
	[window setContentView:view];

	NSBrowser *browser = [view cg_browser];
	check(browser != nil && [browser cg_columnCount] == 256 && [browser cg_activeColumnCount] == 1,
	      "the browser begins with the 256-column pool and the root active");
	check([browser numberOfRowsInColumn:1] == 0 && [browser numberOfVisibleColumns] >= 2,
	      "and an empty slot is a visible column beside it");
	{
		NSView *document = [browser cg_documentView];
		NSScrollView *outer = (NSScrollView *)[[document superview] superview];

		check([outer autohidesScrollers] && [[outer horizontalScroller] isHidden],
		      "and the outer horizontal bar hides when the visible columns fit");
	}
	check([browser columnResizingType] == NSBrowserUserColumnResizing,
	      "and its separators are drag handles");
	check([[browser cg_scrollViewForColumn:0] hasVerticalScroller],
	      "and the column carries its own vertical scroller");
	check([[[browser cg_scrollViewForColumn:0] verticalScroller] isHidden],
	      "which hides while the column's rows fit");
	check([browser numberOfRowsInColumn:0] == 3, "the root column has two folders and a file");
	check([[cellAt(browser, 0, 0) copy] isEqual:@"A Folder"]
	      && [[cellAt(browser, 1, 0) copy] isEqual:@"B Folder"]
	      && [[cellAt(browser, 2, 0) copy] isEqual:@"notes.txt"],
	      "the cells are the model's names, directories first");

	/* SELECTING A BRANCH OPENS THE NEXT COLUMN, AND THE PREVIEW FOLLOWS IT. */
	[browser selectRow:0 inColumn:0];
	check([browser selectedColumn] == 0 && [browser cg_activeColumnCount] == 2
	      && [browser numberOfRowsInColumn:1] == 2,
	      "selecting A Folder loads its two children into column 1");
	check([[[view cg_previewItem] name] isEqual:@"A Folder"],
	      "and the preview is the selected folder");
	check([[view cg_previewText] rangeOfString:@"Folder"].location != NSNotFound,
	      "with a Kind in its text");

	[browser selectRow:0 inColumn:1];
	check([browser cg_activeColumnCount] == 3 && [browser numberOfRowsInColumn:2] == 1,
	      "selecting A Child loads its one child into column 2");
	check([[[view cg_previewItem] name] isEqual:@"A Child"], "and the preview follows to A Child");
	{
		/* **THE FINAL COLUMN IS THE ONE THE PERSON IS LOOKING AT.** The browser's clip view must be at the document's
		 * end after a branch opens its child, so the new column is against the right edge rather than past it. */
		NSView *document = [browser cg_documentView];
		NSView *clip = [document superview];
		CGFloat maxX = [document frame].size.width - [clip bounds].size.width;

		if (maxX < 0.0) {
			maxX = 0.0;
		}
		check(fabs([clip bounds].origin.x - maxX) < 0.01,
		      "navigating into a folder scrolls the columns all the way over");
	}

	[browser selectRow:0 inColumn:2];
	check([browser cg_activeColumnCount] == 3, "a leaf adds no active column to its right");
	check([[[view cg_previewItem] name] isEqual:@"leaf.txt"], "and the leaf is the preview's item");
	check([[view cg_previewText] rangeOfString:@"leaf.txt"].location != NSNotFound
	      && [[view cg_previewText] rangeOfString:@"7 bytes"].location != NSNotFound,
	      "the preview carries the name and the size");

	/* A LEAF IN THE ROOT COLUMN HAS NO RIGHT-HAND COLUMN EITHER. */
	[browser selectRow:2 inColumn:0];
	check([browser cg_activeColumnCount] == 1 && [browser selectedColumn] == 0,
	      "selecting the root's file leaves one active column");
	check([[[view cg_previewItem] name] isEqual:@"notes.txt"], "and the preview is that file");
	check([[WSItemKind kindForItem:[view cg_previewItem]] length] > 0, "with a non-empty Kind");

	/* AN EMPTY BRANCH OPENS NO COLUMN, BUT STILL PREVIEWS. */
	[browser selectRow:1 inColumn:0];
	check([browser cg_activeColumnCount] == 1, "an empty folder opens no column");
	check([[[view cg_previewItem] name] isEqual:@"B Folder"], "but it is the preview's item");

	/* THE VIEW'S OWN OPEN DOOR REACHES THE DELEGATE. */
	[browser selectRow:0 inColumn:0];
	[view openSelectedItem];
	check(probe->opened != nil && [probe->opened isEqual:@"A Folder"],
	      "the selected item is offered to the delegate");

	/* A RELOAD RE-READS THE FOLDER. */
	check(makeFile([aFolder stringByAppendingPathComponent:@"new.txt"], 3), "a new child is created");
	[view reloadData];
	[browser selectRow:0 inColumn:0];
	check([browser numberOfRowsInColumn:1] == 3, "after reload the folder's new child is in column 1");

	/* THE PREVIEW IS A COLUMN OF ITS OWN AND THE BROWSER GETS THE REST. */
	[view setFrameSize:NSMakeSize(900.0, 500.0)];
	check([[browser superview] isEqual:view] && [browser frame].size.width < 900.0
	      && [browser frame].size.height == 500.0,
	      "the browser takes the width beside the preview");
	{
		/* **THE BROWSER'S OWN SCROLL VIEW IS THE PART A FRAME SET CAN FORGET.** `-cg_documentView` is inside the
		 * clip view, which is inside the scroll view; if the browser's `-setFrame:` did not re-tile, the scroll
		 * view keeps the width it had and a gap opens between the last column and the preview panel. */
		NSView *document = [browser cg_documentView];
		NSView *scroll = [[document superview] superview];

		check(scroll != nil
		      && fabs([scroll frame].size.width - [browser bounds].size.width) < 0.01,
		      "and the browser's own scroll view follows its frame");
	}

	[probe release];
	[window release];
	[view release];
	[model release];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];

	printf("column_view: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
