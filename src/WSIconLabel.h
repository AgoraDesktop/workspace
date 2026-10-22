/*
 * WSIconLabel.h — an icon's name cut to the width of its cell.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * THE GRID'S CELL IS THE LIMIT, not the name's own measured width. An icon view draws names under ICONS in a
 * grid, and a name wider than its cell spills into the next one — long directory names stack on top of their
 * neighbours. The cut is in the MIDDLE ("very-long-direc…-name") rather than the tail, so an extension or a
 * distinguishing ending survives, and it is measured with the SAME attributes the drawing uses.
 */
#ifndef WORKSPACE_WSICONLABEL_H
#define WORKSPACE_WSICONLABEL_H

#import <Foundation/NSGeometry.h>
#import <Foundation/NSString.h>

@class NSDictionary;

/* The longest MIDDLE-TRUNCATED form of `name` that measures no wider than `maxWidth`, with an ellipsis when a cut
 * was needed. A name that already fits is returned unchanged. */
NSString *WSIconLabelText(NSString *name, CGFloat maxWidth, NSDictionary *attributes);

#endif /* WORKSPACE_WSICONLABEL_H */
