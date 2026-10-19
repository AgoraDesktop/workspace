/*
 * WSItemSort.h — the list view's ordering rules, separate from both the model and the table.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * **DIRECTORIES FIRST, ALWAYS.** That is the reference file manager's rule and it is not one of the sort keys: a
 * directory is a place before it is a name, and reversing the name order does not put the files above the folders.
 * Within the two groups the key decides: natural name order (`file2` before `file10`), modification date, size, or
 * Kind. Ties fall to the natural name order, so the result is total.
 *
 * The class is pure Foundation plus Icon Services' Kind lookup, which is why `list_view.m` can measure the ordering
 * without a table.
 */
#ifndef WORKSPACE_WSITEMSORT_H
#define WORKSPACE_WSITEMSORT_H

#import <Foundation/NSArray.h>
#import <Foundation/NSObject.h>

typedef enum {
	WSItemSortName = 0,
	WSItemSortDate = 1,
	WSItemSortSize = 2,
	WSItemSortKind = 3
} WSItemSortKey;

@interface WSItemSort : NSObject

/* A stable insertion sort: equal keys keep their input order, which makes the directories-first rule and the tie
 * fallback reproducible. */
+ (NSArray *)sortedItems:(NSArray *)items key:(WSItemSortKey)key ascending:(BOOL)ascending;

@end

#endif /* WORKSPACE_WSITEMSORT_H */
