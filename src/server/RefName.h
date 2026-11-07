/*
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 SEN Labs e.U.
 */
#pragma once

#include <Entry.h>
#include <Path.h>
#include <String.h>

namespace sen {

/**
 * The name of an entry, to show or to compare. Not entry_ref::name: that is the full path with Cosmoe (Linux can't find a
 * folder by its node), and only the name on Haiku.
 */
inline BString
RefName(const entry_ref& ref)
{
	const BPath path(&ref);
	return BString(path.Leaf() != NULL ? path.Leaf() : ref.name);
}

}	// namespace sen
