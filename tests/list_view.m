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
#import "WSFileOperations.h"
#import "WSItemKind.h"
#import "WSItemModel.h"
#import "WSItemSort.h"
#import "WSListView.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSDragging.h>
#import <AppKit/NSPasteboard.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTableColumn.h>
#import <AppKit/NSTableHeaderView.h>
#import <AppKit/NSTextFieldCell.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <objc/runtime.h>
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

/* **A PICTURE OF A KNOWN SIZE**: a decode is what the wait is for, and a PNG of twenty-four by sixteen pixels is one. */
static BOOL writePNG(NSString *path, int width, int height)
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];
	NSData *png;
	BOOL ok;
	int x, y;

	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			[rep setColor:[NSColor colorWithCalibratedRed:(CGFloat)x / width green:(CGFloat)y / height
								blue:0.5 alpha:1.0] atX:x y:y];
		}
	}
	png = [rep representationUsingType:NSPNGFileType properties:nil];
	ok = (png != nil) && [png writeToFile:path atomically:YES];
	[rep release];
	return ok;
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

static NSEvent *leftUp(NSPoint inWindow, NSUInteger flags)
{
	return [NSEvent mouseEventWithType:NSLeftMouseUp location:inWindow modifierFlags:flags
				 timestamp:0.0 windowNumber:0 context:nil
				 eventNumber:0 clickCount:1 pressure:1.0f];
}

static NSEvent *leftDrag(NSPoint inWindow, NSUInteger flags)
{
	return [NSEvent mouseEventWithType:NSLeftMouseDragged location:inWindow modifierFlags:flags
				 timestamp:0.0 windowNumber:0 context:nil
				 eventNumber:0 clickCount:0 pressure:1.0f];
}

/* **THE WINDOW OWNS A CONTEXT MENU'S COMMANDS, SO THE MENU MUST BE AIMED AT IT** — see `WSContextMenuCommandTarget`, and
 * `WSFileWindowController`, which is the real one. This probe is the smallest object that answers `-newFolder:`. */
@interface AGListCommands : NSObject
@end

@implementation AGListCommands
- (void)newFolder:(id)sender { (void)sender; }
- (void)selectAll:(id)sender { (void)sender; }
@end

/* A DRAGGING INFO WITH NO SESSION, so the destination's two doors are asked the way the table asks them. */
@interface AGListDropInfo : NSObject <NSDraggingInfo>
{
	NSPasteboard *_pasteboard;	/* RETAINED */
	NSPoint _location;
	NSDragOperation _mask;
}
- (instancetype)initWithPaths:(NSArray *)paths location:(NSPoint)location;
@end

@implementation AGListDropInfo
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

	/* **A LIST THAT IS ABOUT TO DECODE A PILE OF PICTURES SAYS "WORKING" FIRST.** A folder of photographs asks for an
	 * icon per visible row, and the first draw of each row is a decode: MEASURED at 9 ms a picture, which for a window of
	 * rows is a wait a person can see. The shape belongs to the compositor, so what is measured here is the REQUEST. A
	 * list of documents asks for none, because their icons are lookups rather than decodes. */
	{
		/* **A TREE OF ITS OWN**, so the list this probe has been measuring keeps the rows it had. */
		NSString *waitRoot = [@"/tmp" stringByAppendingPathComponent:
			[NSString stringWithFormat:@"agora-list-wait-%d", (int)getpid()]];
		NSString *pictures = [waitRoot stringByAppendingPathComponent:@"Pictures"];
		NSString *papers = [waitRoot stringByAppendingPathComponent:@"Papers"];
		WSItemModel *pictureModel;
		WSItemModel *paperModel;
		WSListView *pictureList;
		WSListView *paperList;
		NSScrollView *pictureScroll;
		NSScrollView *paperScroll;
		NSWindow *pictureWindow;
		int k;

		[[NSFileManager defaultManager] createDirectoryAtPath:waitRoot withIntermediateDirectories:YES
								   attributes:nil error:NULL];
		[[NSFileManager defaultManager] createDirectoryAtPath:pictures withIntermediateDirectories:YES
								   attributes:nil error:NULL];
		[[NSFileManager defaultManager] createDirectoryAtPath:papers withIntermediateDirectories:YES
								   attributes:nil error:NULL];
		for (k = 0; k < 6; k++) {
			writePNG([pictures stringByAppendingPathComponent:
				[NSString stringWithFormat:@"p%d.png", k]], 24, 16);
			makeFile([papers stringByAppendingPathComponent:
				[NSString stringWithFormat:@"d%d.txt", k]], 4);
		}
		pictureModel = [[WSItemModel alloc] initWithDirectory:pictures];
		paperModel = [[WSItemModel alloc] initWithDirectory:papers];
		pictureList = [[WSListView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 200.0) model:pictureModel];
		paperList = [[WSListView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 200.0) model:paperModel];
		pictureScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 200.0)];
		paperScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 200.0)];
		[pictureScroll setDocumentView:pictureList];
		[paperScroll setDocumentView:paperList];
		pictureWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 200.0)
			styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:YES];
		[pictureWindow setContentView:pictureScroll];
		{
			NSWindow *paperWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 200.0)
				styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:YES];

			[paperWindow setContentView:paperScroll];
			[pictureList displayRect:[pictureList bounds]];
			[paperList displayRect:[paperList bounds]];
			printf("  (note: a list of six pictures asked for the wait %ld time(s); six documents %ld time(s)\n",
			       (long)[pictureList cg_busyCursorUses], (long)[paperList cg_busyCursorUses]);
			check([pictureList cg_busyCursorUses] == 1,
			      "a list that decodes six pictures puts the busy pointer up for the draw");
			check([paperList cg_busyCursorUses] == 0,
			      "a list of documents does not, because it decodes nothing");
			[paperWindow release];
		}
		[pictureWindow release];
		[pictureScroll release];
		[paperScroll release];
		[pictureList release];
		[paperList release];
		[pictureModel release];
		[paperModel release];
	}

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

	/* **2b. A CLICK ON A COLUMN HEADER SORTS BY THAT COLUMN, AND A SECOND CLICK REVERSES IT.** The header sets the
	 * table's sort descriptors; the OUTLINE's contract is a delegate method (`-outlineView:sortDescriptorsDidChange:`),
	 * so a view told in the table's spelling would change the descriptors and nothing else — MEASURED as "the column
	 * headers do not sort the list". This drives the real header of the real scroll view. */
	{
		NSTableHeaderView *header = [list headerView];
		NSInteger sizeColumn = -1;
		NSInteger columnIndex;
		NSRect cell;

		for (columnIndex = 0; columnIndex < (NSInteger)[[list tableColumns] count]; columnIndex++) {
			NSTableColumn *column = [[list tableColumns] objectAtIndex:(NSUInteger)columnIndex];

			if ([[column identifier] isEqual:@"size"]) {
				sizeColumn = columnIndex;
			}
		}
		check(sizeColumn >= 0 && [header superview] != nil,
		      "the header is in the scroll view and has a Size column");
		cell = [header headerRectOfColumn:sizeColumn];
		{
			NSPoint windowPoint = [header convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell)) toView:nil];
			NSEvent *down = [NSEvent mouseEventWithType:NSLeftMouseDown location:windowPoint
						     modifierFlags:0 timestamp:0.0
						      windowNumber:[window windowNumber]
							   context:nil eventNumber:0 clickCount:1 pressure:1.0f];
			NSEvent *up = [NSEvent mouseEventWithType:NSLeftMouseUp location:windowPoint
						   modifierFlags:0 timestamp:0.0
						    windowNumber:[window windowNumber]
							 context:nil eventNumber:0 clickCount:1 pressure:1.0f];

			[header mouseDown:down];
			[header mouseUp:up];
			check([list sortKey] == WSItemSortSize,
			      "clicking the Size header sorts by size");
			check([[[list sortDescriptors] objectAtIndex:0] key] != nil
			      && [[[[list sortDescriptors] objectAtIndex:0] key] isEqual:@"size"],
			      "and the table's own descriptors say so, which is what the header draws from");
			[header mouseDown:down];
			[header mouseUp:up];
			check([list sortKey] == WSItemSortSize && [[list sortDescriptors] count] == 1
			      && [[[list sortDescriptors] objectAtIndex:0] ascending] == NO,
			      "and a second click reverses the same column instead of leaving it");
		}
	}

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

	/* **THE CONTEXT MENU: THE THREE THE ICON SURFACES RAISE, AIMED AT THE WINDOW'S COMMANDS.** A tree has no Cut of its
	 * own — the window owns the selection's meaning, the operation manager and the progress plate — so the rows' target is
	 * the window's delegate, and a probe that answers `-newFolder:` stands in for `WSFileWindowController` here. */
	{
		AGListCommands *commands = [[AGListCommands alloc] init];
		NSPoint inRow0;
		NSPoint inRow1;
		NSPoint below;
		NSMenu *menu;
		NSArray *rows;

		[window setDelegate:commands];
		inRow0 = [list convertPoint:NSMakePoint(NSMidX([list rectOfRow:0]), NSMidY([list rectOfRow:0])) toView:nil];
		inRow1 = [list convertPoint:NSMakePoint(NSMidX([list rectOfRow:1]), NSMidY([list rectOfRow:1])) toView:nil];
		below = [list convertPoint:NSMakePoint(40.0, [list numberOfRows] * [list rowHeight] + 20.0)
				    toView:nil];

		[list selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
		menu = [list menuForEvent:rightClick(inRow0)];
		rows = (menu != nil) ? [menu itemArray] : nil;
		check([rows count] == 8, "a right-click on a list row raises the item's own menu");
		if ([rows count] == 8) {
			check([[[rows objectAtIndex:0] title] isEqual:@"Get Info"]
			      && [[[rows objectAtIndex:5] title] isEqual:@"Rename"]
			      && [[[rows objectAtIndex:6] title] isEqual:@"Compress"]
			      && [[[rows objectAtIndex:7] title] isEqual:@"Move to Trash"],
			      "with the reference file manager's rows, Compress among them");
			check([[rows objectAtIndex:7] target] == commands
			      && [[rows objectAtIndex:6] target] == commands,
			      "aimed at the WINDOW's commands, which is what owns the selection's meaning");
		}

		/* A click on one of several held rows keeps the group, and a group cannot be renamed. */
		[list selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]
	     byExtendingSelection:NO];
		menu = [list menuForEvent:rightClick(inRow1)];
		rows = (menu != nil) ? [menu itemArray] : nil;
		check([[list selectedRowIndexes] count] == 2 && [rows count] == 8
		      && [menu indexOfItemWithTitle:@"New Folder with Selection"] != (NSInteger)NSNotFound
		      && [menu indexOfItemWithTitle:@"Rename"] == (NSInteger)NSNotFound,
		      "a right-click inside a group keeps it and offers the group's rows");

		/* **A CONTROL- OR COMMAND-CLICK ADDS A ROW AND SHIFT TAKES A RUN**, the same rules the table has and the ones a
		 * person arriving from any other file manager will use: Control is not a dead key here. */
		{
			NSPoint row0 = [list convertPoint:NSMakePoint(NSMidX([list rectOfRow:0]),
								      NSMidY([list rectOfRow:0])) toView:nil];
			NSPoint row2 = [list convertPoint:NSMakePoint(NSMidX([list rectOfRow:2]),
								      NSMidY([list rectOfRow:2])) toView:nil];

			[list selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
			[list mouseDown:leftClick(row2, NSControlKeyMask)];
			check([[list selectedRowIndexes] count] == 2 && [list isRowSelected:0]
			      && [list isRowSelected:2],
			      "a Control-click adds a row to the list's selection");
			[list mouseDown:leftClick(row2, NSControlKeyMask)];
			check([[list selectedRowIndexes] count] == 1 && ![list isRowSelected:2],
			      "and a second one takes it away again");
			[list mouseDown:leftClick(row2, NSCommandKeyMask)];
			check([[list selectedRowIndexes] count] == 2 && [list isRowSelected:2],
			      "while a Command-click does the same");
			[list selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
			[list mouseDown:leftClick(row2, NSShiftKeyMask)];
			check([[list selectedRowIndexes] count] == 3 && [list isRowSelected:0]
			      && [list isRowSelected:1] && [list isRowSelected:2],
			      "and a Shift-click takes the run between the anchor and the row clicked");
			check([list numberOfRows] > 2, "the list holds the rows the run crossed");
		}

		/* Below the last row is the folder's own menu. */
		menu = [list menuForEvent:rightClick(below)];
		rows = (menu != nil) ? [menu itemArray] : nil;
		check([rows count] == 4 && [[[rows objectAtIndex:0] title] isEqual:@"New Folder"]
		      && [[[rows objectAtIndex:3] title] isEqual:@"Select All"],
		      "and a right-click below the rows asks the folder's own questions");

		[window setDelegate:nil];
		[commands release];
	}

	/* **AND THE TREE IS A DRAG SOURCE AND A DROP DESTINATION, through the four answers the table asks its data source
	 * for.** The source is one call; the destination is its validate/accept pair, asked with a dragging info that has no
	 * session behind it — exactly what the table passes. */
	{
		NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
		NSArray *offered;
		NSInteger folderRow;
		NSInteger fileRow;
		NSDragOperation operation;
		NSString *doomed;

		/* The rows are named rather than numbered, because an earlier section EXPANDED a folder and the tree's numbering
		 * is not the flat list's afterwards. */
		{
			NSIndexSet *carried = [NSIndexSet indexSetWithIndexesInRange:
				NSMakeRange((NSUInteger)rowForName(list, @"big.bin"), 2)];
			NSString *first = [[list itemAtRow:(NSInteger)[carried firstIndex]] path];
			NSString *second = [[list itemAtRow:(NSInteger)[carried firstIndex] + 1] path];

			[list selectRowIndexes:carried byExtendingSelection:NO];
			check([list tableView:list writeRowsWithIndexes:carried toPasteboard:pasteboard],
			      "the source writes the rows the drag carries");
			offered = [pasteboard propertyListForType:NSFilenamesPboardType];
			check([offered count] == 2 && [[offered objectAtIndex:0] isEqual:first]
			      && [[offered objectAtIndex:1] isEqual:second],
			      "as the paths those rows stand for, in the tree's order");
		}

		/* **A CLICK WITH A SHAKY HAND MOVES NOTHING.** A hand's tremor crosses a four-point threshold during an ordinary
		 * click; a table drag that ends on the next row MOVES the file into that row's folder — the way a 22 GB folder
		 * was taken out of a home directory. A press whose pointer stays inside its own row writes nothing to the
		 * pasteboard and begins no session, so the item cannot move. */
		{
			NSInteger row = rowForName(list, @"big.bin");
			NSRect cell = [list rectOfRow:row];
			NSPoint press = [list convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell)) toView:nil];
			NSPoint jitter = [list convertPoint:NSMakePoint(NSMidX(cell) + 16.0, NSMidY(cell) + 3.0)
						    toView:nil];
			NSString *path = [[list itemAtRow:row] path];

			[list mouseDown:leftClick(press, 0)];
			[list mouseDragged:leftDrag(jitter, 0)];
			check([[NSFileManager defaultManager] fileExistsAtPath:path],
			      "a click whose pointer drifts inside its own row moves nothing");
			check([[list selectedRowIndexes] containsIndex:(NSUInteger)row],
			      "and the row it was on is the row it selected");
		}

		/* A drop ON a folder row goes into that folder. */
		folderRow = rowForName(list, @"alphaDir");
		fileRow = rowForName(list, @"notes.txt");
		doomed = [root stringByAppendingPathComponent:@"notes.txt"];
		{
			AGListDropInfo *info = [[AGListDropInfo alloc]
				initWithPaths:[NSArray arrayWithObject:doomed]
				    location:[list convertPoint:NSMakePoint(NSMidX([list rectOfRow:folderRow]),
									    NSMidY([list rectOfRow:folderRow]))
							 toView:nil]];

			NSUndoManager *undo = [[NSUndoManager alloc] init];
			WSFileOperations *operations = [[WSFileOperations alloc] initWithUndoManager:undo trash:nil];

			/* **A DISCLOSURE TRIANGLE IS NOT A DRAG.** The outline CONSUMES that press — its `-mouseDown:` toggles and
		 * returns without calling the table's — so the table's drag bookkeeping still named the last ordinary click.
		 * A twitch of the hand after opening a folder then began a drag of that stale row, and the click after it
		 * completed the drop: opening a folder moved a file. */
		{
			WSItem *alphaItem = [list cg_itemForPath:alpha];
			NSInteger row = [list rowForItem:alphaItem];
			NSRect triangle = [list frameOfOutlineCellAtRow:row];
			NSString *notesPath = [root stringByAppendingPathComponent:@"notes.txt"];
			NSRect rowRect = [list rectOfRow:[list rowForItem:[list cg_itemForPath:notesPath]]];
			NSPoint inTriangle = [list convertPoint:NSMakePoint(NSMidX(triangle), NSMidY(triangle)) toView:nil];
			NSPoint inRow = [list convertPoint:NSMakePoint(NSMidX(rowRect) + 60.0, NSMidY(rowRect)) toView:nil];

			/* An ordinary click first, so the stale state the bug used is there to be used. */
			[list mouseDown:leftClick(inRow, 0)];
			[list mouseUp:leftUp(inRow, 0)];
			NSRect otherRect = [list rectOfRow:0];
			NSPoint inOtherRow = [list convertPoint:NSMakePoint(NSMidX(otherRect) + 60.0,
									    NSMidY(otherRect)) toView:nil];

			[list mouseDown:leftClick(inTriangle, 0)];
			/* **AND THE HAND MOVES ONTO ANOTHER ROW**, which is what made the stale start point dangerous: a drag
			 * that stays in its own row is refused anyway. */
			[list mouseDragged:leftDrag(inOtherRow, 0)];
			check([NSDraggingSession cg_activeSession] == nil,
			      "opening a disclosure triangle begins no drag, however the hand moves");
			[list mouseUp:leftUp(inOtherRow, 0)];
			check([[NSFileManager defaultManager] fileExistsAtPath:alpha]
			      && [[NSFileManager defaultManager] fileExistsAtPath:notesPath],
			      "and nothing was moved by opening it");
		}

		/* **A DROP THAT MOVES IS UNDOABLE**, which is the safety net a file manager owes anyone: the move a drag
			 * performs is the window's, and Edit▸Undo is where it is taken back. */
			[list setFileOperations:operations];
			operation = [list tableView:list validateDrop:info proposedRow:folderRow
				     proposedDropOperation:NSTableViewDropAbove];
			check(operation == NSDragOperationMove,
			      "a file dropped on a folder row is a Move within the volume");
			check([list tableView:list acceptDrop:info row:folderRow dropOperation:NSTableViewDropOn]
			      && [[NSFileManager defaultManager] fileExistsAtPath:
					[alpha stringByAppendingPathComponent:@"notes.txt"]],
			      "and accepting it moves the file into that folder");
			check(probe->changes > 0, "the window is told the tree changed");
			[undo undo];
			check([[NSFileManager defaultManager] fileExistsAtPath:doomed]
			      && ![[NSFileManager defaultManager] fileExistsAtPath:
					[alpha stringByAppendingPathComponent:@"notes.txt"]],
			      "and one Undo puts the moved file back where it came from");
			[list setFileOperations:nil];
			[operations release];
			[undo release];
			[info release];
		}
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
