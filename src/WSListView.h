/*
 * WSListView.h — the file window's List mode, an `NSOutlineView` over the same model.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * **ONE DIRECTORY'S MODEL BECOMES A TREE BY ASKING FOR CHILD MODELS.** The root is the window's `WSItemModel`; a
 * folder's children are another `WSItemModel` made on first expansion and cached. That keeps the plan's rule — one
 * model per directory, every view a consumer — without putting a parent pointer or a recursive enumeration into
 * `WSItemModel` itself.
 *
 * **EXPANSION IS REMEMBERED BY PATH, NOT BY ITEM IDENTITY.** `NSOutlineView`'s expanded set is identity-based, and a
 * reload makes new `WSItem` objects; the view keeps the set of expanded PATHS and re-expands the matching new items
 * after a reload. That is what makes "the outline's expansion survives a model change" true rather than lucky.
 *
 * **SORTING IS `WSItemSort`'S.** The header's sort prototypes become descriptors; the data source maps the first
 * descriptor to a `WSItemSortKey`, clears the per-directory sort cache and reloads. Directories stay first in both
 * directions, names use natural order, and ties fall to the name.
 *
 * **RENAMING IS THE TABLE'S FIELD EDITOR.** The Name column is editable; the data source's
 * `-outlineView:setObjectValue:forTableColumn:byItem:` performs one `NSFileManager` move, reloads the parent model,
 * restores expansion and selects the new name. Return begins the same session from the keyboard.
 */
#ifndef WORKSPACE_WSLISTVIEW_H
#define WORKSPACE_WSLISTVIEW_H

#import <AppKit/NSOutlineView.h>

#import "WSItemSort.h"

@class NSMutableDictionary;
@class NSMutableSet;
@class NSTableColumn;
@class WSItem;
@class WSItemModel;
@class WSListView;

@protocol WSListViewDelegate <NSObject>
@optional
- (void)listView:(WSListView *)view openItem:(WSItem *)item;
- (void)listViewDidChangeModel:(WSListView *)view;
@end

@interface WSListView : NSOutlineView <NSOutlineViewDataSource, NSOutlineViewDelegate>
{
	WSItemModel *_model;			/* RETAINED: the directory at the root */
	id <WSListViewDelegate> _listDelegate;	/* NOT RETAINED */
	NSMutableDictionary *_childModels;	/* RETAINED: path -> WSItemModel */
	NSMutableDictionary *_sortedCache;	/* RETAINED: directory path -> sorted WSItem array */
	NSMutableDictionary *_kindCache;	/* RETAINED: item path -> Kind string */
	NSMutableSet *_expandedPaths;		/* RETAINED: paths open across a reload */
	WSItemSortKey _sortKey;
	BOOL _sortAscending;
	BOOL _restoringExpansion;
}
- (instancetype)initWithFrame:(NSRect)frame model:(WSItemModel *)model;

- (void)setModel:(WSItemModel *)model;
- (nullable WSItemModel *)model;

- (nullable id <WSListViewDelegate>)listDelegate;
- (void)setListDelegate:(nullable id <WSListViewDelegate>)delegate;

- (WSItemSortKey)sortKey;
- (void)setSortKey:(WSItemSortKey)key ascending:(BOOL)ascending;

- (nullable WSItem *)selectedItem;
- (BOOL)beginEditingSelectedName;
- (void)openSelectedItem;

/* The item at a path in the tree, or nil. It creates the child model needed to look inside an open folder. */
- (nullable WSItem *)cg_itemForPath:(NSString *)path;
- (NSArray *)cg_expandedPaths;

@end

#endif /* WORKSPACE_WSLISTVIEW_H */
