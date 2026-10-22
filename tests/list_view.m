/*
 * list_view — W4: columns, directories-first natural order, the tree across a reload, and inline rename.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE ORDERING IS ASKED OF `WSItemSort`, AND THE VIEW IS ASKED TO SHOW IT.** Directories first is a rule about
 * groups; natural order is a rule about digits (`file2` before `file10`); date, size and Kind are the three column
 * keys. The outline's expansion is checked ACROSS a reload, because that is the property an identity-based expanded
 * set loses: the reload makes new `WSItem` objects and the view has to re-expand by path. Rename uses the table's
 * field editor and one `NSFileManager` move. **And the Name cell carries the item's icon**, set through the same
 * `-outlineView:willDisplayCell:…` door the table uses, so a row's picture is checked without a window.
 */
#import "WSItemKind.h"
#import "WSItemModel.h"
#import "WSItemSort.h"
#import "WSListView.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTableColumn.h>
#import <AppKit/NSTextFieldCell.h>
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

static BOOL makeDirectory(NSString *path)
{
	return [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
								  attributes:nil error:NULL];
}

static BOOL makeFile(NSString *path, NSUInteger bytes)
{
	NSMutableData *data = [NSMutableData dataWithLength:bytes];

	return [[NSFileManager defaultManager] createFileAtPath:path contents:data attributes:nil];
}

static void setDate(NSString *path, double seconds)
{
	NSDate *date = [NSDate dateWithTimeIntervalSince1970:seconds];
	NSDictionary *attributes = [NSDictionary dictionaryWithObject:date forKey:NSFileModificationDate];

	(void)[[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:path error:NULL];
}

static NSString *rowName(WSListView *view, NSInteger row)
{
	WSItem *item = (WSItem *)[view itemAtRow:row];

	return (item != nil) ? [item name] : nil;
}

static NSInteger rowForName(WSListView *view, NSString *name)
{
	NSInteger i;

	for (i = 0; i < [view numberOfRows]; i++) {
		if ([rowName(view, i) isEqual:name]) {
			return i;
		}
	}
	return -1;
}

static NSString *objectFor(WSListView *view, NSInteger row, NSString *identifier);

static BOOL rowIs(WSListView *view, NSInteger row, NSString *name)
{
	return [rowName(view, row) isEqual:name];
}

static BOOL objectIs(WSListView *view, NSInteger row, NSString *identifier, NSString *value)
{
	return [objectFor(view, row, identifier) isEqual:value];
}

static BOOL rowExists(WSListView *view, NSString *name)
{
	return rowForName(view, name) >= 0;
}

static NSString *objectFor(WSListView *view, NSInteger row, NSString *identifier)
{
	NSTableColumn *column = [view tableColumnWithIdentifier:identifier];
	WSItem *item = (WSItem *)[view itemAtRow:row];

	return (NSString *)[view outlineView:view objectValueForTableColumn:column byItem:item];
}

@interface AGListProbe : NSObject <WSListViewDelegate>
{
@public
	NSString *opened;
	int changes;
}
@end

@implementation AGListProbe
- (void)listView:(WSListView *)view openItem:(WSItem *)item
{
	(void)view;
	[opened release];
	opened = [[item name] copy];
}
- (void)listViewDidChangeModel:(WSListView *)view
{
	(void)view;
	changes++;
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
		[NSString stringWithFormat:@"agora-list-view-%d", (int)getpid()]];
	NSString *alpha = [root stringByAppendingPathComponent:@"alphaDir"];
	NSString *folder2 = [root stringByAppendingPathComponent:@"Folder 2"];
	NSString *folder10 = [root stringByAppendingPathComponent:@"Folder 10"];
	NSString *zeta = [root stringByAppendingPathComponent:@"ZetaDir"];
	WSItemModel *model;
	WSListView *list;
	NSWindow *window;
	NSScrollView *scroll;
	AGListProbe *probe;

	setvbuf(stdout, NULL, _IONBF, 0);
	[application finishLaunching];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	check(makeDirectory(root), "the probe made its temporary tree");
	makeDirectory(alpha);
	makeDirectory(folder2);
	makeDirectory(folder10);
	makeDirectory(zeta);
	makeFile([root stringByAppendingPathComponent:@"big.bin"], 3000);
	makeFile([root stringByAppendingPathComponent:@"File1.txt"], 1);
	makeFile([root stringByAppendingPathComponent:@"file2.txt"], 2);
	makeFile([root stringByAppendingPathComponent:@"file10.txt"], 10);
	makeFile([root stringByAppendingPathComponent:@"notes.txt"], 50);
	makeFile([alpha stringByAppendingPathComponent:@"inside.txt"], 7);

	/* Controlled dates: oldest to newest in the order the date test expects. */
	setDate(alpha, 1500000000.0);
	setDate(zeta, 1500000100.0);
	setDate(folder2, 1500000200.0);
	setDate(folder10, 1500000300.0);
	setDate([root stringByAppendingPathComponent:@"big.bin"], 1500000400.0);
	setDate([root stringByAppendingPathComponent:@"File1.txt"], 1500000500.0);
	setDate([root stringByAppendingPathComponent:@"file2.txt"], 1500000600.0);
	setDate([root stringByAppendingPathComponent:@"file10.txt"], 1500000700.0);
	setDate([root stringByAppendingPathComponent:@"notes.txt"], 1500000800.0);

	model = [[WSItemModel alloc] initWithDirectory:root];
	list = [[WSListView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 700.0, 400.0) model:model];
	probe = [[AGListProbe alloc] init];
	[list setListDelegate:probe];
	window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 700.0, 400.0)
					     styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
	scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 700.0, 400.0)];
	[scroll setHasVerticalScroller:YES];
	[scroll setAutohidesScrollers:YES];
	[scroll setDocumentView:list];
	[window setContentView:scroll];
	[list reloadData];

	/* 1. NAME ORDER: DIRECTORIES FIRST, THEN NATURAL NUMBERS. */
	check([list numberOfRows] == 9, "the outline shows the four folders and five files");
	check(rowIs(list, 0, @"alphaDir")
	       && rowIs(list, 1, @"Folder 2")
	       && rowIs(list, 2, @"Folder 10")
	       && rowIs(list, 3, @"ZetaDir"),
	      "the folders come first, and 2 precedes 10 naturally");
	check(rowIs(list, 4, @"big.bin")
	       && rowIs(list, 5, @"File1.txt")
	       && rowIs(list, 6, @"file2.txt")
	       && rowIs(list, 7, @"file10.txt")
	       && rowIs(list, 8, @"notes.txt"),
	      "then the files, with file2 before file10");

	/* 2. THE COLUMNS READ THE MODEL'S OWN FACTS. */
	check(objectIs(list, 0, @"kind", @"Folder"), "a directory's Kind is Folder");
	check(objectIs(list, 6, @"size", @"2 bytes"), "a file's Size is its bytes");
	check([(objectFor(list, 6, @"date")) rangeOfString:@"-"].location != NSNotFound,
	      "and its Date is a formatted date");
	check([[WSItemKind kindForItem:(WSItem *)[list itemAtRow:6]] length] > 0,
	      "a file's Kind is non-empty");

	/* 3. THE OTHER THREE KEYS, EACH STILL DIRECTORIES-FIRST. */
	[list setSortKey:WSItemSortSize ascending:YES];
	check(rowIs(list, 4, @"File1.txt")
	       && rowIs(list, 5, @"file2.txt")
	       && rowIs(list, 6, @"file10.txt")
	       && rowIs(list, 7, @"notes.txt")
	       && rowIs(list, 8, @"big.bin"),
	      "size ascending orders the files 1, 2, 10, 50, 3000 and keeps the folders first");

	[list setSortKey:WSItemSortDate ascending:YES];
	check(rowIs(list, 0, @"alphaDir") && rowIs(list, 3, @"Folder 10")
	       && rowIs(list, 4, @"big.bin") && rowIs(list, 8, @"notes.txt"),
	      "date ascending walks the controlled modification times, folders first");

	[list setSortKey:WSItemSortKind ascending:YES];
	{
		NSInteger i;
		BOOL monotonic = YES;

		for (i = 5; i < [list numberOfRows]; i++) {
			NSString *a = objectFor(list, i - 1, @"kind");
			NSString *b = objectFor(list, i, @"kind");

			if ([a caseInsensitiveCompare:b] == NSOrderedDescending) monotonic = NO;
		}
		check(monotonic, "Kind ascending keeps the files' kinds in order");
	}

	/* REVERSING A COLUMN REVERSES EACH GROUP, NOT THE DIRECTORY RULE. */
	[list setSortKey:WSItemSortName ascending:NO];
	check(rowIs(list, 0, @"ZetaDir") && rowIs(list, 1, @"Folder 10")
	      && rowIs(list, 2, @"Folder 2") && rowIs(list, 3, @"alphaDir"),
	      "name descending keeps the folders first and reverses their order");
	check(rowIs(list, 4, @"notes.txt") && rowIs(list, 8, @"big.bin"),
	      "and reverses the files");

	/* 4. EXPANSION IS BY PATH AND SURVIVES A RELOAD. */
	[list setSortKey:WSItemSortName ascending:YES];
	{
		WSItem *alphaItem = [list cg_itemForPath:alpha];
		WSItem *inside;

		[list expandItem:alphaItem];
		inside = [list cg_itemForPath:[alpha stringByAppendingPathComponent:@"inside.txt"]];
		check(inside != nil && [list rowForItem:inside] >= 0,
		      "expanding a folder shows its child");
		check([[list cg_expandedPaths] containsObject:alpha], "and the expanded path is remembered");
	}

	/* A new file changes the model's contents; the reload makes new items, but the path and the selection stay. */
	{
		NSInteger notesRow = rowForName(list, @"notes.txt");

		[list selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)notesRow]
		   byExtendingSelection:NO];
	}
	check(makeFile([root stringByAppendingPathComponent:@"new.txt"], 3), "a new file is created");
	[[list model] reload];
	[list reloadData];
	{
		WSItem *alphaItem = [list cg_itemForPath:alpha];
		WSItem *inside = [list cg_itemForPath:[alpha stringByAppendingPathComponent:@"inside.txt"]];

		check(alphaItem != nil && [list isItemExpanded:alphaItem],
		      "the folder is still expanded after the reload");
		check(inside != nil && [list rowForItem:inside] >= 0,
		      "and its child is still a visible row");
		check(rowExists(list, @"new.txt"), "the new item is in the model");
		check([[list selectedItem] name] != nil
		      && [[[list selectedItem] name] isEqual:@"notes.txt"],
		      "and the selected path survived the reload");
	}

	/* 5. INLINE RENAME THROUGH THE FIELD EDITOR. */
	{
		NSInteger row = rowForName(list, @"File1.txt");
		NSText *editor;
		NSCell *cell;

		[list selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
		check([list beginEditingSelectedName], "Return/begin starts editing the Name column");
		editor = [list currentEditor];
		check(editor != nil, "and the table lends its field editor");
		if (editor != nil) {
			[editor setString:@"renamed.txt"];
			cell = [list preparedCellAtColumn:0 row:row];
			[(NSTextFieldCell *)cell endEditing:editor];
		}
		check([[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"renamed.txt"]]
		      && ![[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"File1.txt"]],
		      "ending the session renames the file on disk");
		check(rowForName(list, @"renamed.txt") >= 0, "and the row follows the new name");
		check(probe->changes > 0, "and the delegate is told the model changed");
	}

	/* 6. RETURN OPENS THE EDITOR; RIGHT/LEFT OPEN AND CLOSE A FOLDER. */
	{
		NSInteger row = rowForName(list, @"renamed.txt");
		NSEvent *ret = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:0
					 timestamp:0.0 windowNumber:0 context:nil
					 characters:@"\r" charactersIgnoringModifiers:@"\r"
					 isARepeat:NO keyCode:36];

		[list selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
		[list keyDown:ret];
		check([list currentEditor] != nil, "Return on a row begins the rename session");
		[list abortEditing];
	}
	{
		NSInteger row = rowForName(list, @"Folder 2");
		WSItem *item = (WSItem *)[list itemAtRow:row];
		unichar right = NSRightArrowFunctionKey;
		unichar left = NSLeftArrowFunctionKey;
		NSEvent *rightEvent = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:0
						     timestamp:0.0 windowNumber:0 context:nil
						     characters:[NSString stringWithCharacters:&right length:1]
						     charactersIgnoringModifiers:[NSString stringWithCharacters:&right length:1]
						     isARepeat:NO keyCode:124];
		NSEvent *leftEvent = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:0
						    timestamp:0.0 windowNumber:0 context:nil
						    characters:[NSString stringWithCharacters:&left length:1]
						    charactersIgnoringModifiers:[NSString stringWithCharacters:&left length:1]
						    isARepeat:NO keyCode:123];

		[list selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
		[list keyDown:rightEvent];
		check([list isItemExpanded:item], "Right opens a selected folder");
		[list keyDown:leftEvent];
		check(![list isItemExpanded:item], "and Left closes it");
	}

	/* 7. COMMAND-DOWN ASKS THE DELEGATE TO OPEN. */
	{
		NSInteger row = rowForName(list, @"notes.txt");
		unichar down = NSDownArrowFunctionKey;
		NSEvent *event = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint
					    modifierFlags:NSCommandKeyMask timestamp:0.0 windowNumber:0 context:nil
					    characters:[NSString stringWithCharacters:&down length:1]
					    charactersIgnoringModifiers:[NSString stringWithCharacters:&down length:1]
					    isARepeat:NO keyCode:125];

		[list selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
		[list keyDown:event];
		check(probe->opened != nil && [probe->opened isEqual:@"notes.txt"],
		      "Command-Down asks the delegate to open the selected item");
	}

	/* AN UNREGISTERED EXTENSION MUST NOT SHOW A DYNAMIC UTI AS ITS KIND. */
	{
		NSString *oddPath = [root stringByAppendingPathComponent:@"todo.md"];
		WSItem *odd;

		makeFile(oddPath, 4);
		odd = [[WSItem alloc] initWithName:@"todo.md" path:oddPath isDirectory:NO];
		{
			NSString *kind = [WSItemKind kindForItem:odd];

			check([kind length] > 0 && [kind rangeOfString:@"dyn."].location == NSNotFound,
			      "an undeclared extension falls back to a readable kind, not dyn.…");
		}
		[odd release];
	}

	/* 8. THE ROW'S ICON, THROUGH THE SAME `willDisplayCell` DOOR THE TABLE USES. */
	{
		NSInteger folderRow = rowForName(list, @"Folder 2");
		NSInteger fileRow = rowForName(list, @"notes.txt");
		NSCell *folderCell = [list preparedCellAtColumn:0 row:folderRow];
		NSCell *fileCell = [list preparedCellAtColumn:0 row:fileRow];
		NSCell *dateCell = [list preparedCellAtColumn:1 row:fileRow];

		check([folderCell image] != nil && [[folderCell image] size].width == 16.0
		      && [[folderCell image] size].height == 16.0,
		      "a folder row's Name cell carries its 16-point icon");
		check([fileCell image] != nil, "a file row's Name cell carries its type's icon");
		check([dateCell image] == nil, "and a non-Name cell carries no icon of its own");
	}

	[probe release];
	[scroll release];
	[window release];
	[list release];
	[model release];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];

	printf("list_view: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
