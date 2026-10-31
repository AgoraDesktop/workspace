/*
 * WSIconCell.m — the wash, the icon, the name and the ring, in that order.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSIconCell.h"

#import "WSIconLayout.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSStringDrawing.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSString.h>

#include <math.h>

NSColor *WSIconCellSelectionColor(void)
{
	/* **A WASH, NOT A PLATE.** Thirty-five percent of the selection's blue: enough to say "this one" over white and over a
	 * wallpaper, and never enough to hide what it is saying it about. */
	return [NSColor colorWithCalibratedRed:0.30 green:0.50 blue:0.90 alpha:0.35];
}

/* **THE AIR BETWEEN AN ICON AND ITS NAME, AS ONE NUMBER FOR BOTH SURFACES.** Two points put the first row of ink about
 * six below the icon (a line's own leading accounts for the rest) — a little more than the desktop's old band showed and a
 * little less than the file window's, which is the middle the design owner asked for. */
const NSInteger WSIconLabelGap = 1;
const NSInteger WSIconHighlightInset = 2;
const NSInteger WSIconHighlightRadius = 4;
const NSInteger WSIconHighlightSlop = 2;

/* **THE NAME'S RECTANGLE, ON WHICHEVER SIDE THE VIEW PUTS IT.** A cut name has an advance, and the rectangle handed to
 * `-drawInRect:` is exactly as wide, ROUNDED UP because a rect exactly as wide as the advance clips the last glyph. */
static NSRect fn_label_rect(NSRect iconRect, BOOL labelBelow, CGFloat labelWidth, CGFloat labelHeight)
{
	CGFloat y = labelBelow ? NSMaxY(iconRect) + (CGFloat)WSIconLabelGap
			       : NSMinY(iconRect) - (CGFloat)WSIconLabelGap - labelHeight;

	return NSMakeRect(NSMidX(iconRect) - labelWidth / 2.0, y, labelWidth, labelHeight);
}

NSRect WSIconCellHighlightRect(NSRect iconRect, CGFloat cellWidth, BOOL labelBelow)
{
	CGFloat side = (cellWidth - iconRect.size.width) / 2.0;

	return NSMakeRect(iconRect.origin.x - side,
			  labelBelow
				? iconRect.origin.y - (CGFloat)WSIconHighlightInset
				: NSMinY(iconRect) - (CGFloat)WSIconLabelGap - (CGFloat)WSIconLabelHeight
				  - (CGFloat)WSIconHighlightInset,
			  cellWidth,
			  iconRect.size.height + (CGFloat)WSIconLabelGap + (CGFloat)WSIconLabelHeight +
			  2.0 * (CGFloat)WSIconHighlightInset);
}

void WSIconCellDraw(WSIconCell cell)
{
	/* **THE NAME IS CENTRED ON THE ICON, NOT ON THE CELL.** The cell's left edge is the icon's and carries its padding to
	 * the right, so a name centred on the cell sat a padded half-cell off the folder it named. */
	NSRect highlight = WSIconCellHighlightRect(cell.iconRect, cell.cellWidth, cell.labelBelow);

	if (cell.selected) {
		NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:highlight
								      xRadius:(CGFloat)WSIconHighlightRadius
								      yRadius:(CGFloat)WSIconHighlightRadius];

		/* **A SELECTED CELL IS A PLATE, NOT A TINT ON WHATEVER IS BEHIND IT.** A thirty-five percent wash says "this one"
		 * over a white page and disappears over a dark wallpaper, so the same selection looked like two different things on
		 * two surfaces — which is exactly the report this answers. The white is laid down FIRST and the wash over it, so a
		 * selected desktop icon has the SAME pixels as a selected icon in a file window, whatever is behind the desktop. */
		[[NSColor whiteColor] setFill];
		[shape fill];
		[WSIconCellSelectionColor() setFill];
		[shape fill];
	}
	if (cell.icon != nil) {
		[cell.icon drawInRect:cell.iconRect];
	}
	if (cell.label != nil) {
		/* **THE INK ON A SELECTED CELL IS THE PLATE'S, NOT THE SURFACE'S.** With the plate beneath it, black is the ink that
		 * reads on both surfaces — so a selected name is black on a desktop and in a file window alike, while an UNSELECTED
		 * desktop name stays white because what is behind it is a wallpaper. */
		NSDictionary *attributes = cell.selected
			? [NSDictionary dictionaryWithObjectsAndKeys:[NSColor blackColor],
					   NSForegroundColorAttributeName, nil]
			: cell.attributes;
		NSSize size = [cell.label sizeWithAttributes:attributes];
		/* **THE BOX IS THE TEXT'S OWN HEIGHT, NOT A BAND OF SIXTEEN.** A fixed band leaves the space between the icon and
		 * the first row of ink up to whatever the drawing engine does inside it — and that answer differs by a point or two
		 * between a flipped view and an unflipped one, which is a gap that cannot be reasoned about and cannot be tuned. A
		 * box the height of the line leaves only the font's own leading, which is the same on both surfaces. */
		NSRect rect = fn_label_rect(cell.iconRect, cell.labelBelow, ceil(size.width), ceil(size.height));

		/* **CLIPPED TO THE HIGHLIGHT, WHICH IS THE LAST GUARD AGAINST A NAME SPILLING INTO ITS NEIGHBOUR.** The cut has
		 * already made it fit the cell; the clip is what keeps a rounding error or a kern pair inside. */
		[NSGraphicsContext saveGraphicsState];
		[[NSBezierPath bezierPathWithRect:highlight] addClip];
		[cell.label drawInRect:rect withAttributes:attributes];
		[NSGraphicsContext restoreGraphicsState];
	}
	/* **THE RING IS THE HIGHLIGHT'S OUTLINE AND IT IS DRAWN LAST**, so it is never painted over — and it goes on the
	 * same rectangle as the wash, which is what makes the colour and the outline one shape. */
	if (cell.selected && cell.focused) {
		[[NSColor darkGrayColor] setStroke];
		[[NSBezierPath bezierPathWithRoundedRect:highlight
						 xRadius:(CGFloat)WSIconHighlightRadius
						 yRadius:(CGFloat)WSIconHighlightRadius] stroke];
	}
}
