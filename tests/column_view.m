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
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSBrowser.h>
#import <AppKit/NSBrowserCell.h>
#import <AppKit/NSDragging.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSPasteboard.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTableColumn.h>
#import <AppKit/NSTableView.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdio.h>
#include <unistd.h>

/* **THE BROWSER'S DATA-SOURCE HALF, DECLARED HERE AS THE OTHER PROBES DECLARE A PRIVATE SEAM.** A column's table asks its
 * data source — the browser — for the four drag answers, and the browser forwards them to its delegate. Calling these is
 * what measures the whole path rather than only the view's half of it. */
@interface NSBrowser (AGColumnDragProbe)
- (BOOL)tableView:(NSTableView *)tableView writeRowsWithIndexes:(NSIndexSet *)rowIndexes
   toPasteboard:(NSPasteboard *)pasteboard;
- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id <NSDraggingInfo>)info
		 proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation;
- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id <NSDraggingInfo>)info
	       row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation;
@end

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

static NSEvent *rightClick(NSPoint inWindow)
{
	return [NSEvent mouseEventWithType:NSRightMouseDown location:inWindow modifierFlags:0
				 timestamp:0.0 windowNumber:0 context:nil
				 eventNumber:0 clickCount:1 pressure:1.0f];
}

static NSEvent *leftClick(NSPoint inWindow, NSUInteger flags)
{
	return [NSEvent mouseEventWithType:NSLeftMouseDown location:inWindow modifierFlags:flags
				 timestamp:0.0 windowNumber:0 context:nil
				 eventNumber:0 clickCount:1 pressure:1.0f];
}

/* **THE WINDOW OWNS A CONTEXT MENU'S COMMANDS**, so a probe that answers `-newFolder:` stands in for
 * `WSFileWindowController` — the same stand-in the list view's suite uses. */
@interface AGColumnCommands : NSObject
@end

@implementation AGColumnCommands
- (void)newFolder:(id)sender { (void)sender; }
- (void)selectAll:(id)sender { (void)sender; }
@end

/* A DRAGGING INFO WITH NO SESSION, so the browser's forwards are asked the way its columns' tables ask them. */
@interface AGColumnDropInfo : NSObject <NSDraggingInfo>
{
	NSPasteboard *_pasteboard;	/* RETAINED */
	NSPoint _location;
	NSDragOperation _mask;
}
- (instancetype)initWithPaths:(NSArray *)paths location:(NSPoint)location;
@end

@implementation AGColumnDropInfo
- (instancetype)initWithPaths:(NSArray *)paths location:(NSPoint)location
{
	self = [super init];
	if (self != nil) {
		_pasteboard = [[NSPasteboard pasteboardWithUniqueName] retain];
		[_pasteboard declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
		[_pasteboard setPropertyList:paths forType:NSFilenamesPboardType];
		_location = location;
		_mask = NSDragOperationEvery;
	}
	return self;
}
- (void)dealloc
{
	[_pasteboard release];
	[super dealloc];
}
- (NSPasteboard *)draggingPasteboard { return _pasteboard; }
- (NSPoint)draggingLocation { return _location; }
- (NSDragOperation)draggingSourceOperationMask { return _mask; }
- (id)draggingSource { return nil; }
- (NSInteger)draggingSequenceNumber { return 0; }
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

	/* **AN EMPTY BRANCH OPENS ITS OWN COLUMN, EMPTY, WITH ITS NAME ON IT.** A folder with nothing in it is still a place
	 * a person went: Apple's browser shows the column beside it with a blank list, and counting only columns that have
	 * rows hid it — "when the selected directory is empty, there is no column shown for it". */
	[browser selectRow:1 inColumn:0];
	check([browser cg_activeColumnCount] == 2 && [browser numberOfRowsInColumn:1] == 0,
	      "an empty folder opens a column beside it, with no rows in it");
	check([[browser titleOfColumn:1] isEqual:@"B Folder"],
	      "and that column is titled for the empty folder, which is the place the person opened");
	check([[[view cg_previewItem] name] isEqual:@"B Folder"], "and it is the preview's item");

	/* **AND THE FIRST COLUMN IS NAMED FOR THE FOLDER THE WINDOW SHOWS.** It has no column to its left to take a name
	 * from, and answering nil left the leftmost header blank. */
	check([[browser titleOfColumn:0] isEqual:[root lastPathComponent]],
	      "the first column is titled for the folder the window shows");
	check([[browser titleOfColumn:0] length] > 0, "so no column in the browser is left without a header");

	/* **A DOUBLE-CLICK IS WHAT OPENS AN ITEM**, and a column's rows answer it through the browser's double action. */
	{
		NSTableView *table = [browser cg_tableForColumn:0];
		NSRect cell = [browser frameOfRow:0 inColumn:0];
		NSPoint inWindow = [browser convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell)) toView:nil];
		NSEvent *down = [NSEvent mouseEventWithType:NSLeftMouseDown location:inWindow
					       modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
					      eventNumber:0 clickCount:2 pressure:1.0f];

		probe->opened = nil;
		[browser selectRow:0 inColumn:0];
		[table mouseDown:down];
		printf("  (debug: after a double click in column zero, opened = %s)\n",
		       probe->opened != nil ? [probe->opened UTF8String] : "(nil)");
		check(probe->opened != nil && [probe->opened isEqual:@"A Folder"],
		      "a double-click in a column reaches the view's open door");
	}

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

	/* **A TRASHED FILE LEAVES THE COLUMNS WHERE THEY WERE.** Removing the leaf selected in column 1 and reloading is
	 * exactly what Move to Trash does to the view: the two columns must survive, column 1 must come back with nothing
	 * selected rather than the browser collapsing to column zero, and the preview must empty while column 0 keeps the
	 * folder a person was inside. */
	[browser selectRow:0 inColumn:0];
	{
		NSInteger leafRow = -1;
		NSInteger row;

		for (row = 0; row < [browser numberOfRowsInColumn:1]; row++) {
			if ([cellAt(browser, row, 1) isEqual:@"new.txt"]) {
				leafRow = row;
			}
		}
		check(leafRow >= 0, "the folder's new child is selectable in column 1");
		[browser selectRow:leafRow inColumn:1];
		check([[[view cg_previewItem] name] isEqual:@"new.txt"], "and it is the preview's item");
		check([[NSFileManager defaultManager] removeItemAtPath:
			[aFolder stringByAppendingPathComponent:@"new.txt"] error:NULL],
		      "the selected file goes away, as Move to Trash makes it");
		[view reloadData];
		check([browser cg_activeColumnCount] == 2 && [browser selectedColumn] == 0,
		      "the reloaded browser keeps both columns and selects the folder, not the file");
		check([browser selectedRowInColumn:1] == -1,
		      "and the column that held the trashed file is open with nothing selected");
		check([view cg_previewItem] == nil, "while the preview empties rather than describing a gone file");
		check([[cellAt(browser, [browser selectedRowInColumn:0], 0) copy] isEqual:@"A Folder"],
		      "and column 0 still holds the folder the person was in");
		check([browser numberOfRowsInColumn:1] == 2, "whose remaining children are still listed");
	}

	/* **A COLUMN HOLDS SEVERAL ROWS, WHICH IS WHAT THE MODIFIERS ARE FOR.** Control and Command add a row to the
	 * column's selection and Shift takes the run from the anchor, so Move to Trash, Copy or a drag can take several
	 * files of one folder — the whole reason a browser's columns are multi-selection. The browser still opens the
	 * column to the right from the first selected row, so browsing stays predictable. */
	{
		NSTableView *table = [browser cg_tableForColumn:0];
		NSPoint row0 = [browser convertPoint:NSMakePoint(NSMidX([browser frameOfRow:0 inColumn:0]),
								NSMidY([browser frameOfRow:0 inColumn:0]))
					   toView:nil];
		NSPoint row2 = [browser convertPoint:NSMakePoint(NSMidX([browser frameOfRow:2 inColumn:0]),
								NSMidY([browser frameOfRow:2 inColumn:0]))
					   toView:nil];

		[browser selectRow:0 inColumn:0];
		[table mouseDown:leftClick(row2, NSControlKeyMask)];
		check([[view selectedItems] count] == 2 && [browser selectedColumn] == 0,
		      "a Control-click adds a row of the column to the selection");
		check([[[[view selectedItems] objectAtIndex:1] name] isEqual:@"notes.txt"],
		      "and the group is the rows the two clicks named");
		[table mouseDown:leftClick(row2, NSControlKeyMask)];
		check([[view selectedItems] count] == 1, "a second Control-click takes it away again");
		[table mouseDown:leftClick(row2, NSCommandKeyMask)];
		check([[view selectedItems] count] == 2, "and a Command-click adds one back");
		[browser selectRow:0 inColumn:0];
		[table mouseDown:leftClick(row2, NSShiftKeyMask)];
		check([[view selectedItems] count] == 3,
		      "a Shift-click takes the run between the anchor and the row clicked");
		[browser selectRow:0 inColumn:0];
		check([[view selectedItems] count] == 1, "and a plain selection is one row again");
	}

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

	/* **THE CONTEXT MENU IS THE BROWSER'S, because the event lands on it and not on the wrapper.** The row under the
	 * pointer comes from the browser's own hit test, and the rows are aimed at the WINDOW, which owns the commands. */
	{
		AGColumnCommands *commands = [[AGColumnCommands alloc] init];
		NSInteger row = [browser selectedRowInColumn:0];
		NSMenu *menu;
		NSArray *rows;

		[window setDelegate:commands];
		{
			/* A point inside the first row of column zero: the browser's own hit test is asked for the row's rect. */
			NSRect cell = [browser frameOfRow:(row >= 0 ? row : 0) inColumn:0];
			NSPoint inWindow = [browser convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell)) toView:nil];

			menu = [browser menuForEvent:rightClick(inWindow)];
		}
		rows = (menu != nil) ? [menu itemArray] : nil;
		check([rows count] == 7, "a right-click on a column's row raises the item's own menu");
		if ([rows count] == 7) {
			check([[[rows objectAtIndex:0] title] isEqual:@"Get Info"]
			      && [[[rows objectAtIndex:6] title] isEqual:@"Move to Trash"],
			      "with the reference file manager's rows");
			check([[rows objectAtIndex:6] target] == commands,
			      "aimed at the WINDOW's commands, not at the browser");
		}

		/* **A RIGHT-CLICK INSIDE A GROUP KEEPS IT AND OFFERS THE GROUP'S ROWS**, the rule the list follows: narrowing
		 * the click to one row would leave the commands a group is for with nothing to act on. */
		{
			NSTableView *table = [browser cg_tableForColumn:0];
			NSRect cell = [browser frameOfRow:0 inColumn:0];
			NSPoint inWindow = [browser convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell)) toView:nil];
			NSRect other = [browser frameOfRow:2 inColumn:0];
			NSPoint otherWindow = [browser convertPoint:NSMakePoint(NSMidX(other), NSMidY(other)) toView:nil];

			[browser selectRow:0 inColumn:0];
			[table mouseDown:leftClick(otherWindow, NSControlKeyMask)];
			menu = [browser menuForEvent:rightClick(inWindow)];
			rows = (menu != nil) ? [menu itemArray] : nil;
			check([[browser selectedRowIndexesInColumn:0] count] == 2
			      && [menu indexOfItemWithTitle:@"New Folder with Selection"] != (NSInteger)NSNotFound
			      && [menu indexOfItemWithTitle:@"Rename"] == (NSInteger)NSNotFound,
			      "a right-click inside a group keeps it and offers the group's rows");
			[browser selectRow:0 inColumn:0];
		}

		/* Below the last row of the column is the folder's own menu. */
		{
			NSInteger count = [browser numberOfRowsInColumn:0];
			NSRect last = [browser frameOfRow:(count - 1) inColumn:0];
			NSPoint below = [browser convertPoint:NSMakePoint(NSMidX(last), NSMinY(last) - 20.0)
						       toView:nil];

			menu = [browser menuForEvent:rightClick(below)];
		}
		rows = (menu != nil) ? [menu itemArray] : nil;
		check([rows count] == 4 && [[[rows objectAtIndex:0] title] isEqual:@"New Folder"],
		      "and a right-click below the rows asks the folder's own questions");
		check([[[view cg_commandDirectory] lastPathComponent] isEqual:[root lastPathComponent]],
		      "and the folder those rows are about is the one column zero shows");

		/* **AND THE FOLDER IS THE COLUMN'S, NOT THE WINDOW'S.** A browser shows a chain of folders at once, so the rows
		 * of a right-click in the SECOND column belong to the folder that column lists — MEASURED as "new directory in
		 * the third column currently creates a new directory in the first". The command directory is what the window's
		 * New Folder and Paste read, so it is what this records. */
		{
			NSInteger rowsInFirst;

			[browser selectRow:0 inColumn:0];
			rowsInFirst = [browser numberOfRowsInColumn:1];
			check(rowsInFirst > 0, "selecting a folder fills the column beside it");
			if (rowsInFirst > 0) {
				NSRect last = [browser frameOfRow:(rowsInFirst - 1) inColumn:1];
				NSPoint below = [browser convertPoint:NSMakePoint(NSMidX(last), NSMinY(last) - 20.0)
							       toView:nil];

				menu = [browser menuForEvent:rightClick(below)];
				rows = (menu != nil) ? [menu itemArray] : nil;
				check([rows count] == 4, "a right-click below the rows of the SECOND column asks a folder's questions");
				printf("  (note: column 1's command directory is %s)\n",
				       [[view cg_commandDirectory] UTF8String]);
				check([[view cg_commandDirectory] isEqual:aFolder],
				      "and that folder is the one the second column lists, not the window's");
			}
			[browser selectRow:0 inColumn:0];
		}

		[window setDelegate:nil];
		[commands release];
	}

	/* **THE PREVIEW PANE'S CONTENTS ARE CENTRED.** The picture and the four facts sat against a twenty-point left margin,
	 * which read as the top of a list rather than as a panel about one item. Rendered and counted, because "centred" is a
	 * property of the ink: the pane's own pixels are measured, and the ink's middle must be the pane's middle. */
	{
		const NSInteger paneWidth = 240;
		NSInteger width = (NSInteger)[view bounds].size.width;
		NSInteger height = (NSInteger)[view bounds].size.height;
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
			pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
			isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
			bytesPerRow:width * 4 bitsPerPixel:32];
		NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
		NSGraphicsContext *previous = [[NSGraphicsContext currentContext] retain];
		NSInteger left = width - paneWidth;
		NSInteger minX = width;
		NSInteger maxX = -1;
		NSInteger x, y;

		/* THE PANE ALREADY HAS AN ITEM: the selection this probe has been making is what it draws. */
		[NSGraphicsContext setCurrentContext:context];
		[view displayRect:[view bounds]];
		[NSGraphicsContext setCurrentContext:previous];
		[previous release];
		for (y = 0; y < height; y++) {
			for (x = left; x < width; x++) {
				NSColor *pixel = [[rep colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];

				/* THE PANE'S OWN FACE IS 0.97 WHITE AND ITS LEFT RULE 0.78; anything darker is the item's. */
				if (pixel != nil && [pixel redComponent] < 0.6) {
					if (x < minX) minX = x;
					if (x > maxX) maxX = x;
				}
			}
		}
		printf("  (note: the preview's ink runs %ld..%ld in a %ld-wide pane)\n",
		       (long)(minX - left), (long)(maxX - left), (long)paneWidth);
		check(maxX >= minX, "the preview draws something to measure");
		check(maxX >= minX && labs(((minX + maxX) / 2) - (left + paneWidth / 2)) <= 4,
		      "and its ink is centred in the pane rather than against the left margin");
		check(maxX >= minX && minX > left + 40,
		      "so nothing begins at the old twenty-point margin");
		[rep release];
	}

	/* **AND A COLUMN IS A DRAG SOURCE AND A DROP DESTINATION, THROUGH THE BROWSER'S OWN FORWARDS.** The three answers go
	 * through the browser (it is the tables' data source) to the view, which is its delegate — so what is measured is the
	 * whole path, not just the view's method. */
	{
		NSTableView *table = [browser cg_tableForColumn:0];
		NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
		NSArray *offered;
		NSInteger fileRow;
		NSInteger folderRow;
		NSString *doomed;
		NSDragOperation operation;

		fileRow = -1;
		folderRow = -1;
		{
			/* **THE ROWS ARE NAMED BY THEIR CELLS.** This browser is driven through the CELL-based delegate contract
			 * (`-browser:willDisplayCell:atRow:column:`), so a row's name is the cell's string — the item-based
			 * `-itemAtRow:inColumn:` is the other contract and answers nothing here. */
			NSInteger i;

			for (i = 0; i < [browser numberOfRowsInColumn:0]; i++) {
				NSString *name = [[browser loadedCellAtRow:i column:0] stringValue];

				if ([name isEqual:@"notes.txt"]) fileRow = i;
				if ([name isEqual:@"B Folder"]) folderRow = i;
			}
		}
		check(fileRow >= 0 && folderRow >= 0 && fileRow != folderRow,
		      "the probe found the file's row and the folder's row");

		check([browser tableView:table writeRowsWithIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)fileRow]
			     toPasteboard:pasteboard],
		      "the browser asks its delegate what the rows offer, and they offer their paths");
		offered = [pasteboard propertyListForType:NSFilenamesPboardType];
		check([offered count] == 1
		      && [[offered objectAtIndex:0] isEqual:[root stringByAppendingPathComponent:@"notes.txt"]],
		      "as the path that row stands for");

		doomed = [root stringByAppendingPathComponent:@"notes.txt"];
		{
			AGColumnDropInfo *info = [[AGColumnDropInfo alloc]
				initWithPaths:[NSArray arrayWithObject:doomed]
				    location:[browser convertPoint:NSMakePoint(10.0, 10.0) toView:nil]];

			operation = [browser tableView:table validateDrop:info proposedRow:folderRow
				     proposedDropOperation:NSTableViewDropAbove];
			check(operation == NSDragOperationMove,
			      "a file dropped on a folder's row is a Move within the volume");
			check([browser tableView:table acceptDrop:info row:folderRow
				  dropOperation:NSTableViewDropOn]
			      && [[NSFileManager defaultManager] fileExistsAtPath:
					[bFolder stringByAppendingPathComponent:@"notes.txt"]],
			      "and accepting it moves the file into that folder");
			[info release];
		}
	}

	[probe release];
	[window release];
	[view release];
	[model release];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];

	printf("column_view: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
