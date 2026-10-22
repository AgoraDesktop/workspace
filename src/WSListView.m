/*
 * WSListView.m — the list mode: columns, a tree, sorting and rename.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSListView.h"

#import "WSFileOperations.h"
#import "WSItemIcons.h"
#import "WSItemKind.h"
#import "WSItemModel.h"

#import <AppKit/NSImage.h>
#import <AppKit/NSTableHeaderCell.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSText.h>
#import <AppKit/NSTextFieldCell.h>
#import <AppKit/NSWindow.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSIndexSet.h>
#import <Foundation/NSNotification.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSString.h>

#include <time.h>

static NSString * const WSListNameColumn = @"name";
static NSString * const WSListDateColumn = @"date";
static NSString * const WSListSizeColumn = @"size";
static NSString * const WSListKindColumn = @"kind";

/* **A NAME CELL THAT CAN SHOW THE ITEM'S ICON, and the shift is in `-drawingRectForBounds:` rather than only
 * in the drawing.** That one door is what the field editor's frame comes from too (`NSTextFieldCell
 * -selectWithFrame:…` asks it), so an icon in a list row does not put the rename editor's text under the
 * picture. The 16-point box and the 20-point advance are the sidebar's own measures (`WSPlaceCell`, in
 * `WSFileWindowController.m`), kept identical so a place and a file name wear their icons the same way. */
@interface WSListNameCell : NSTextFieldCell
@end

@implementation WSListNameCell
- (NSRect)drawingRectForBounds:(NSRect)rect
{
	NSRect room = [super drawingRectForBounds:rect];

	if ([self image] != nil) {
		room.origin.x += 20.0;
		room.size.width -= 20.0;
	}
	return room;
}

- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
	NSImage *image = [self image];

	if (image != nil) {
		NSRect box = NSMakeRect(NSMinX(cellFrame) + 2.0,
					NSMidY(cellFrame) - 8.0, 16.0, 16.0);

		[image drawInRect:box];
	}
	[super drawInteriorWithFrame:cellFrame inView:controlView];
}
@end

/* ---- the two display strings and the expansion's depth order --------------------------------- */

static NSString *fn_date_string(NSDate *date)
{
	time_t seconds;
	struct tm broken;
	char buffer[32];

	if (date == nil) {
		return @"--";
	}
	seconds = (time_t)[date timeIntervalSince1970];
	if (localtime_r(&seconds, &broken) == NULL) {
		return @"--";
	}
	strftime(buffer, sizeof buffer, "%Y-%m-%d %H:%M", &broken);
	return [NSString stringWithUTF8String:buffer];
}

static NSString *fn_size_string(WSItem *item)
{
	unsigned long long size;

	if ([item isDirectory]) {
		return @"--";
	}
	size = [item size];
	if (size < 1024ULL) {
		return [NSString stringWithFormat:@"%llu bytes", size];
	}
	if (size < 1024ULL * 1024ULL) {
		return [NSString stringWithFormat:@"%.1f KB", (double)size / 1024.0];
	}
	if (size < 1024ULL * 1024ULL * 1024ULL) {
		return [NSString stringWithFormat:@"%.1f MB", (double)size / (1024.0 * 1024.0)];
	}
	return [NSString stringWithFormat:@"%.1f GB", (double)size / (1024.0 * 1024.0 * 1024.0)];
}

static NSInteger fn_path_depth_compare(id left, id right, void *context)
{
	NSUInteger ld = 0, rd = 0, i;

	(void)context;
	for (i = 0; i < [(NSString *)left length]; i++) {
		if ([(NSString *)left characterAtIndex:i] == '/') ld++;
	}
	for (i = 0; i < [(NSString *)right length]; i++) {
		if ([(NSString *)right characterAtIndex:i] == '/') rd++;
	}
	if (ld < rd) return NSOrderedAscending;
	if (ld > rd) return NSOrderedDescending;
	return [(NSString *)left compare:(NSString *)right];
}

@implementation WSListView

- (instancetype)initWithFrame:(NSRect)frame model:(WSItemModel *)model
{
	NSTableColumn *name;
	NSTableColumn *date;
	NSTableColumn *size;
	NSTableColumn *kind;

	self = [super initWithFrame:frame];
	if (self == nil) {
		return nil;
	}
	_model = [model retain];
	_childModels = [[NSMutableDictionary alloc] init];
	_sortedCache = [[NSMutableDictionary alloc] init];
	_kindCache = [[NSMutableDictionary alloc] init];
	_expandedPaths = [[NSMutableSet alloc] init];
	_sortKey = WSItemSortName;
	_sortAscending = YES;

	name = [[NSTableColumn alloc] initWithIdentifier:WSListNameColumn];
	[[name headerCell] setStringValue:@"Name"];
	{
		WSListNameCell *cell = [[WSListNameCell alloc] initTextCell:@""];

		[cell setBordered:NO];
		[cell setBezeled:NO];
		[cell setDrawsBackground:NO];
		[name setDataCell:cell];
		[cell release];
	}
	[name setWidth:260.0];
	[name setMinWidth:120.0];
	[name setEditable:YES];
	[name setSortDescriptorPrototype:[NSSortDescriptor sortDescriptorWithKey:WSListNameColumn ascending:YES]];

	date = [[NSTableColumn alloc] initWithIdentifier:WSListDateColumn];
	[[date headerCell] setStringValue:@"Date Modified"];
	[date setWidth:150.0];
	[date setMinWidth:100.0];
	[date setSortDescriptorPrototype:[NSSortDescriptor sortDescriptorWithKey:WSListDateColumn ascending:YES]];

	size = [[NSTableColumn alloc] initWithIdentifier:WSListSizeColumn];
	[[size headerCell] setStringValue:@"Size"];
	[size setWidth:90.0];
	[size setMinWidth:60.0];
	[[size dataCell] setAlignment:NSRightTextAlignment];
	[size setSortDescriptorPrototype:[NSSortDescriptor sortDescriptorWithKey:WSListSizeColumn ascending:YES]];

	kind = [[NSTableColumn alloc] initWithIdentifier:WSListKindColumn];
	[[kind headerCell] setStringValue:@"Kind"];
	[kind setWidth:140.0];
	[kind setMinWidth:80.0];
	[kind setSortDescriptorPrototype:[NSSortDescriptor sortDescriptorWithKey:WSListKindColumn ascending:YES]];

	[self addTableColumn:name];
	[self addTableColumn:date];
	[self addTableColumn:size];
	[self addTableColumn:kind];
	[self setOutlineTableColumn:name];
	[name release];
	[date release];
	[size release];
	[kind release];

	[self setRowHeight:20.0];
	[self setIndentationPerLevel:16.0];
	[self setIndentationMarkerFollowsCell:YES];
	[self setAutoresizesOutlineColumn:YES];
	[self setAllowsMultipleSelection:YES];
	[self setAllowsEmptySelection:YES];
	[self setUsesAlternatingRowBackgroundColors:YES];
	[self setGridStyleMask:NSTableViewGridNone];
	[self setIntercellSpacing:NSMakeSize(3.0, 2.0)];
	[self setSortDescriptors:[NSArray arrayWithObject:
		[NSSortDescriptor sortDescriptorWithKey:WSListNameColumn ascending:YES]]];
	[self setTarget:self];
	[self setDoubleAction:@selector(rowDoubleClicked:)];
	[self setDataSource:self];
	[self setDelegate:self];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidExpand:)
		name:NSOutlineViewItemDidExpandNotification object:self];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidCollapse:)
		name:NSOutlineViewItemDidCollapseNotification object:self];

	[self reloadData];
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_model release];
	[_fileOperations release];
	[_childModels release];
	[_sortedCache release];
	[_kindCache release];
	[_expandedPaths release];
	[super dealloc];
}

- (WSItemModel *)model { return _model; }

- (void)setModel:(WSItemModel *)model
{
	if (_model == model) {
		return;
	}
	[model retain];
	[_model release];
	_model = model;
	[_expandedPaths removeAllObjects];
	[_childModels removeAllObjects];
	[_sortedCache removeAllObjects];
	[_kindCache removeAllObjects];
	[self deselectAll:nil];
	[self reloadData];
}

- (id <WSListViewDelegate>)listDelegate { return _listDelegate; }
- (void)setListDelegate:(id <WSListViewDelegate>)delegate { _listDelegate = delegate; }
- (void)setFileOperations:(WSFileOperations *)operations
{
	[operations retain];
	[_fileOperations release];
	_fileOperations = operations;
}

- (WSItemSortKey)sortKey { return _sortKey; }

/* ---- THE TREE AND THE SORT CACHE ------------------------------------------------------------- */

- (WSItemModel *)modelForItem:(WSItem *)item
{
	WSItemModel *child;
	NSString *path;

	if (item == nil || ![item isDirectory]) {
		return nil;
	}
	path = [item path];
	child = [_childModels objectForKey:path];
	if (child == nil) {
		child = [[WSItemModel alloc] initWithDirectory:path];
		[_childModels setObject:child forKey:path];
		[child release];
	}
	return child;
}

- (NSArray *)sortedItemsForModel:(WSItemModel *)model
{
	NSString *key;
	NSArray *sorted;

	if (model == nil) {
		return [NSArray array];
	}
	key = [model directory];
	sorted = [_sortedCache objectForKey:key];
	if (sorted == nil) {
		sorted = [WSItemSort sortedItems:[model items] key:_sortKey ascending:_sortAscending];
		[_sortedCache setObject:sorted forKey:key];
	}
	return sorted;
}

- (NSArray *)itemsForItem:(WSItem *)item
{
	return [self sortedItemsForModel:(item == nil) ? _model : [self modelForItem:item]];
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
	(void)outlineView;
	return (NSInteger)[[self itemsForItem:(WSItem *)item] count];
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item
{
	(void)outlineView;
	return [[self itemsForItem:(WSItem *)item] objectAtIndex:(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
	(void)outlineView;
	return (item != nil) && [(WSItem *)item isDirectory];
}

- (WSItem *)cg_itemForPath:(NSString *)path
{
	return [self itemForPath:path inModel:_model];
}

- (WSItem *)itemForPath:(NSString *)path inModel:(WSItemModel *)model
{
	NSArray *items = [self sortedItemsForModel:model];
	NSUInteger i;

	for (i = 0; i < [items count]; i++) {
		WSItem *item = [items objectAtIndex:i];

		if ([[item path] isEqual:path]) {
			return item;
		}
		if ([item isDirectory]
		    && [path hasPrefix:[[item path] stringByAppendingString:@"/"]]) {
			WSItem *found = [self itemForPath:path inModel:[self modelForItem:item]];

			if (found != nil) {
				return found;
			}
		}
	}
	return nil;
}

- (NSArray *)cg_expandedPaths
{
	return [_expandedPaths allObjects];
}

/* ---- THE CELLS ------------------------------------------------------------------------------- */

- (NSString *)kindForItem:(WSItem *)item
{
	NSString *path = [item path];
	NSString *kind = [_kindCache objectForKey:path];

	if (kind == nil) {
		kind = [WSItemKind kindForItem:item];
		[_kindCache setObject:kind forKey:path];
	}
	return kind;
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn
	   byItem:(id)item
{
	NSString *identifier = (tableColumn != nil) ? (NSString *)[tableColumn identifier] : nil;
	WSItem *entry = (WSItem *)item;

	(void)outlineView;
	if (entry == nil) {
		return nil;
	}
	if ([identifier isEqual:WSListNameColumn]) {
		return [entry name];
	}
	if ([identifier isEqual:WSListDateColumn]) {
		return fn_date_string([entry modificationDate]);
	}
	if ([identifier isEqual:WSListSizeColumn]) {
		return fn_size_string(entry);
	}
	if ([identifier isEqual:WSListKindColumn]) {
		return [self kindForItem:entry];
	}
	return nil;
}

/* **THE ROW'S ICON IS THE CELL'S IMAGE, and it is set per row because the table reuses one cell for the
 * column.** The cell asks Icon Services through `WSItemIcons` — the same lookup the desktop, the sidebar and
 * the icon view use — at the 16 points a list row has room for. Every other column is cleared, because the
 * cells are separate but the rule that a data cell's state belongs to THIS row is what keeps a recycled cell
 * from carrying a folder's picture into the date column. */
- (void)outlineView:(NSOutlineView *)outlineView willDisplayCell:(id)cell
     forTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
	NSString *identifier = (tableColumn != nil) ? (NSString *)[tableColumn identifier] : nil;

	(void)outlineView;
	if ([identifier isEqual:WSListNameColumn] && item != nil) {
		WSItem *entry = (WSItem *)item;

		[cell setImage:[WSItemIcons iconForPath:[entry path]
							isDirectory:[entry isDirectory]
							       size:16]];
	} else {
		[cell setImage:nil];
	}
}

/* ---- RENAME, THROUGH THE TABLE'S FIELD EDITOR ------------------------------------------------ */

- (WSItemModel *)modelForParentOfItem:(WSItem *)item
{
	NSString *parent = [[item path] stringByDeletingLastPathComponent];
	WSItemModel *model;

	if ([parent isEqual:[_model directory]]) {
		return _model;
	}
	model = [_childModels objectForKey:parent];
	return model;
}

- (BOOL)renameItem:(WSItem *)item toName:(NSString *)name
{
	WSItemModel *parent;
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *newPath;
	BOOL renamed = NO;

	name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (item == nil || [name length] == 0 || [name isEqual:@"."] || [name isEqual:@".."]
	    || [name rangeOfString:@"/"].location != NSNotFound) {
		[self reloadData];
		return NO;
	}
	if ([name isEqual:[item name]]) {
		return YES;
	}
	newPath = [[[item path] stringByDeletingLastPathComponent] stringByAppendingPathComponent:name];
	if ([manager fileExistsAtPath:newPath]) {
		[self reloadData];
		return NO;
	}
	parent = [self modelForParentOfItem:item];
	if ((_fileOperations != nil)
	    ? ([_fileOperations renamePath:[item path] toName:name error:NULL] != nil)
	    : [manager moveItemAtPath:[item path] toPath:newPath error:NULL]) {
		[parent reload];
		[_childModels removeAllObjects];
		[_sortedCache removeAllObjects];
		[_kindCache removeAllObjects];
		[self reloadData];
		{
			WSItem *renamedItem = [self cg_itemForPath:newPath];
			NSInteger row = (renamedItem != nil) ? [self rowForItem:renamedItem] : -1;

			if (row >= 0) {
				[self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
				   byExtendingSelection:NO];
			}
		}
		if ([_listDelegate respondsToSelector:@selector(listViewDidChangeModel:)]) {
			[_listDelegate listViewDidChangeModel:self];
		}
		renamed = YES;
	} else {
		[self reloadData];
	}
	return renamed;
}

/* **THE TABLE'S ROW FORM, BECAUSE THE SUBJECT OF THIS EDIT IS A ROW.** An `NSOutlineView` is an `NSTableView`, and
 * its field editor ends through the TABLE data-source door with a row number; this view is the data source, so it
 * maps the row back to its item and performs the same rename the outline-shaped door would. (The outline-shaped
 * method below stays for a caller that drives the item API directly; the two cannot disagree because both call
 * `-renameItem:toName:`.) */
- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object
   forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	WSItem *item;

	(void)tableView;
	if (tableColumn == nil || ![[tableColumn identifier] isEqual:WSListNameColumn] || object == nil) {
		return;
	}
	item = (WSItem *)[self itemAtRow:row];
	if (item != nil) {
		(void)[self renameItem:item toName:(NSString *)object];
	}
}

- (void)outlineView:(NSOutlineView *)outlineView setObjectValue:(id)object
     forTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
	(void)outlineView;
	if (tableColumn != nil && [[tableColumn identifier] isEqual:WSListNameColumn]
	    && object != nil) {
		(void)[self renameItem:(WSItem *)item toName:(NSString *)object];
	}
}

/* ---- SORTING --------------------------------------------------------------------------------- */

- (WSItemSortKey)keyForDescriptorKey:(NSString *)key
{
	if ([key isEqual:WSListDateColumn]) return WSItemSortDate;
	if ([key isEqual:WSListSizeColumn]) return WSItemSortSize;
	if ([key isEqual:WSListKindColumn]) return WSItemSortKind;
	return WSItemSortName;
}

- (NSString *)descriptorKeyForSortKey:(WSItemSortKey)key
{
	if (key == WSItemSortDate) return WSListDateColumn;
	if (key == WSItemSortSize) return WSListSizeColumn;
	if (key == WSItemSortKind) return WSListKindColumn;
	return WSListNameColumn;
}

- (void)outlineView:(NSOutlineView *)outlineView sortDescriptorsDidChange:(NSArray *)oldDescriptors
{
	NSSortDescriptor *descriptor = ([[outlineView sortDescriptors] count] > 0)
		? [[outlineView sortDescriptors] objectAtIndex:0] : nil;

	(void)oldDescriptors;
	_sortKey = [self keyForDescriptorKey:(descriptor != nil) ? [descriptor key] : nil];
	_sortAscending = (descriptor != nil) ? [descriptor ascending] : YES;
	[_sortedCache removeAllObjects];
	[self reloadData];
}

- (void)setSortKey:(WSItemSortKey)key ascending:(BOOL)ascending
{
	NSSortDescriptor *descriptor;

	if (key < WSItemSortName || key > WSItemSortKind) {
		return;
	}
	_sortKey = key;
	_sortAscending = ascending;
	descriptor = [NSSortDescriptor sortDescriptorWithKey:[self descriptorKeyForSortKey:key]
						     ascending:ascending];
	[self setSortDescriptors:[NSArray arrayWithObject:descriptor]];
	[_sortedCache removeAllObjects];
	[self reloadData];
}

/* ---- EXPANSION ACROSS A RELOAD ---------------------------------------------------------------- */

- (NSArray *)selectedPaths
{
	NSIndexSet *rows = [self selectedRowIndexes];
	NSMutableArray *paths = [[NSMutableArray alloc] init];
	NSUInteger row;

	for (row = [rows firstIndex]; row != NSNotFound; row = [rows indexGreaterThanIndex:row]) {
		WSItem *item = (WSItem *)[self itemAtRow:(NSInteger)row];

		if (item != nil) {
			[paths addObject:[item path]];
		}
	}
	return [paths autorelease];
}

- (void)reloadData
{
	NSArray *selectedPaths = [self selectedPaths];
	NSArray *expanded = [[_expandedPaths allObjects] sortedArrayUsingFunction:fn_path_depth_compare
									context:NULL];
	NSMutableIndexSet *rows = [[NSMutableIndexSet alloc] init];
	NSUInteger i;

	/* THE CHILD MODELS ARE REBUILT, because their directories may have changed. The expanded PATHS are what is kept;
	 * a reload's new WSItem objects are matched to them below. */
	[_childModels removeAllObjects];
	[_sortedCache removeAllObjects];
	[_kindCache removeAllObjects];
	[super reloadData];

	_restoringExpansion = YES;
	for (i = 0; i < [expanded count]; i++) {
		NSString *path = [expanded objectAtIndex:i];
		WSItem *item = [self cg_itemForPath:path];

		if (item != nil && [item isDirectory]) {
			[self expandItem:item];
		} else {
			[_expandedPaths removeObject:path];
		}
	}
	_restoringExpansion = NO;

	for (i = 0; i < [selectedPaths count]; i++) {
		WSItem *item = [self cg_itemForPath:[selectedPaths objectAtIndex:i]];
		NSInteger row = (item != nil) ? [self rowForItem:item] : -1;

		if (row >= 0) {
			[rows addIndex:(NSUInteger)row];
		}
	}
	[self selectRowIndexes:rows byExtendingSelection:NO];
	[rows release];
	[self tile];
}

- (void)itemDidExpand:(NSNotification *)notification
{
	id item;

	if (_restoringExpansion) {
		return;
	}
	item = [[notification userInfo] objectForKey:NSOutlineViewItemKey];
	if (item != nil) {
		[_expandedPaths addObject:[(WSItem *)item path]];
	}
}

- (void)itemDidCollapse:(NSNotification *)notification
{
	id item;

	if (_restoringExpansion) {
		return;
	}
	item = [[notification userInfo] objectForKey:NSOutlineViewItemKey];
	if (item != nil) {
		[_expandedPaths removeObject:[(WSItem *)item path]];
	}
}

/* ---- THE KEYBOARD AND THE DOUBLE-CLICK -------------------------------------------------------- */

- (WSItem *)selectedItem
{
	NSInteger row = [self selectedRow];

	return (row >= 0) ? (WSItem *)[self itemAtRow:row] : nil;
}

- (BOOL)beginEditingSelectedName
{
	NSInteger row = [self selectedRow];

	if (row < 0) {
		return NO;
	}
	[self editColumn:0 row:row withEvent:nil select:YES];
	return YES;
}

- (NSArray *)selectedItems
{
	NSIndexSet *rows = [self selectedRowIndexes];
	NSMutableArray *items = [[NSMutableArray alloc] init];
	NSUInteger row;

	for (row = [rows firstIndex]; row != NSNotFound; row = [rows indexGreaterThanIndex:row]) {
		WSItem *item = (WSItem *)[self itemAtRow:(NSInteger)row];

		if (item != nil) {
			[items addObject:item];
		}
	}
	return [items autorelease];
}

- (void)openSelectedItem
{
	WSItem *item = [self selectedItem];

	if (item != nil && [_listDelegate respondsToSelector:@selector(listView:openItem:)]) {
		[_listDelegate listView:self openItem:item];
	}
}

- (void)rowDoubleClicked:(id)sender
{
	NSInteger row = [self clickedRow];

	(void)sender;
	if (row < 0) {
		row = [self selectedRow];
	}
	if (row >= 0) {
		WSItem *item = (WSItem *)[self itemAtRow:row];

		if (item != nil && [_listDelegate respondsToSelector:@selector(listView:openItem:)]) {
			[_listDelegate listView:self openItem:item];
		}
	}
}

- (void)keyDown:(NSEvent *)event
{
	NSString *characters = [event characters];
	unichar character;
	NSUInteger flags = [event modifierFlags];
	WSItem *item;

	if ([characters length] == 0) {
		[super keyDown:event];
		return;
	}
	character = [characters characterAtIndex:0];
	if ((flags & NSCommandKeyMask) != 0 && character == NSDownArrowFunctionKey) {
		[self openSelectedItem];
		return;
	}
	if (character == '\r' || character == '\n') {
		[self beginEditingSelectedName];
		return;
	}
	item = [self selectedItem];
	if (character == NSRightArrowFunctionKey && item != nil && [item isDirectory]
	    && ![self isItemExpanded:item]) {
		[self expandItem:item];
		return;
	}
	if (character == NSLeftArrowFunctionKey && item != nil && [item isDirectory]
	    && [self isItemExpanded:item]) {
		[self collapseItem:item];
		return;
	}
	[super keyDown:event];
}

@end
