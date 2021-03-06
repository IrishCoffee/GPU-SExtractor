 /*
 				field.c

*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
*
*	Part of:	SExtractor
*
*	Author:		E.BERTIN (IAP)
*
*	Contents:	Handling of field structures.
*
*	Last modify:	19/12/2007
*
*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
*/

#ifdef HAVE_CONFIG_H
#include        "config.h"
#endif

#include	<math.h>
#include	<stdio.h>
#include	<stdlib.h>
#include	<string.h>

#include	"define.h"
#include	"globals.h"
#include	"prefs.h"
#include	"fits/fitscat.h"
#include	"assoc.h"
#include	"astrom.h"
#include	"back.h"
#include	"field.h"
#include	"filter.h"
#include	"fitswcs.h"
#include	"interpolate.h"

/********************************* newfield **********************************/
/*
Returns a pointer to a new field, ready to go!
*/
picstruct	*newfield(char *filename, int flags, int nok)

  {
   picstruct	*field;
   catstruct	*cat;
   tabstruct	*tab;
   int		nok2, ntab, margin;

/* Move to nok'th valid FITS image extension */
  if (!(cat = read_cat(filename)))
    error(EXIT_FAILURE, "*Error*: cannot open ", filename);

/* First allocate memory for the new field (and nullify pointers) */
  QCALLOC(field, picstruct, 1);
  field->flags = flags;
  field->cat = cat;
  tab = cat->tab;
  nok++;	/* At least one pass through the loop */
  nok2 = nok;
  for (ntab=cat->ntab; nok && ntab--; tab=tab->nexttab)
    {
    if ((tab->naxis < 2)
	|| !strncmp(tab->xtension, "BINTABLE", 8)
	|| !strncmp(tab->xtension, "ASCTABLE", 8))
      continue;
    field->tab = tab;
    nok--;
    }
  if (ntab<0)
    error(EXIT_FAILURE, "Not enough valid FITS image extensions in ",filename);

  strcpy (field->filename, filename);
/* A short, "relative" version of the filename */
  if (!(field->rfilename = strrchr(field->filename, '/')))
    field->rfilename = field->filename;
  else
    field->rfilename++;

  sprintf(gstr, "Looking for %s", field->rfilename);
  NFPRINTF(OUTPUT, gstr);
/* Check the image exists and read important info (image size, etc...) */
  field->file = cat->file;
  
  readimagehead(field);

  if (cat->ntab>1)
    sprintf(gstr, "[%d/%d]", nok2, cat->tab->naxis<2? cat->ntab-1 : cat->ntab);
  QPRINTF(OUTPUT, "%s \"%.20s\" %s / %d x %d / %d bits %s data\n",
	flags&FLAG_FIELD?   "Flagging  from:" :
       (flags&(RMS_FIELD|VAR_FIELD|WEIGHT_FIELD)?
			     "Weighting from:" :
       (flags&MEASURE_FIELD? "Measuring from:" :
			     "Detecting from:")),
	field->ident,
        cat->ntab>1? gstr : "",
	field->width, field->height, field->bytepix*8,
	field->bitpix>0?
	(field->tab->compress_type!=COMPRESS_NONE?"COMPRESSED":"INTEGER")
	:"FLOATING POINT");

/* Check the astrometric system and do the setup of the astrometric stuff */
  if (prefs.world_flag && (flags & (MEASURE_FIELD|DETECT_FIELD)))
    initastrom(field);
  else
    field->pixscale=prefs.pixel_scale;

/* Gain and Saturation */
  if (flags & (DETECT_FIELD|MEASURE_FIELD))
    {
    if (fitsread(field->tab->headbuf, prefs.gain_key, &field->gain,
	H_FLOAT, T_DOUBLE) != RETURN_OK)
      field->gain = prefs.gain;
    if (fitsread(field->tab->headbuf, prefs.satur_key, &field->satur_level,
	H_FLOAT, T_DOUBLE) !=RETURN_OK)
      field->satur_level = prefs.satur_level;
    }

/* Background */
  if (flags & (DETECT_FIELD|MEASURE_FIELD|WEIGHT_FIELD|VAR_FIELD|RMS_FIELD))
    {
    field->ngamma = prefs.mag_gamma/log(10.0);

    field->backw = prefs.backsize[0]<field->width ? prefs.backsize[0]
						  : field->width;
    field->backh = prefs.backsize[1]<field->height ? prefs.backsize[1]
						   : field->height;
    field->nbackp = field->backw * field->backh;
    if ((field->nbackx = (field->width-1)/field->backw + 1) < 1)
      field->nbackx = 1;
    if ((field->nbacky = (field->height-1)/field->backh + 1) < 1)
      field->nbacky = 1;
    field->nback = field->nbackx * field->nbacky;
    field->nbackfx = field->nbackx>1 ? prefs.backfsize[0] : 1;
    field->nbackfy = field->nbacky>1 ? prefs.backfsize[1] : 1;
/*--  Set the back_type flag if absolute background is selected */
    if (((flags & DETECT_FIELD) && prefs.back_type[0]==BACK_ABSOLUTE)
	|| ((flags & MEASURE_FIELD) && prefs.back_type[1]==BACK_ABSOLUTE))
      field->back_type = BACK_ABSOLUTE;
    }

/* Add a comfortable margin for local background estimates */
  margin = (prefs.pback_type == LOCAL)? prefs.pback_size + prefs.mem_bufsize/4
					: 0;

  field->stripheight = prefs.mem_bufsize + margin;
  if (field->stripheight>field->height)
    field->stripheight = field->height;
/* Compute the image buffer size */
/* Basically, only one margin line is sufficient... */
  field->stripmargin = 1 + margin;
/* ...but : */
  if (prefs.filter_flag)
    {
/*-- If filtering is on, one should consider the height of the conv. mask */
    if (field->stripheight < thefilter->convh)
      field->stripheight = thefilter->convh;
    if (field->stripmargin < (margin = (thefilter->convh-1)/2))
      field->stripmargin = margin;
    }

  return field;
  }


/******************************* inheritfield *******************************/
/*
Make a copy of a field structure, e.g. for interpolation purposes.
*/
picstruct	*inheritfield(picstruct *infield, int flags)

  {
   picstruct	*field;

/* First allocate memory for the new field (and nullify pointers) */
  QCALLOC(field, picstruct, 1);

/* Copy what is important and reset the remaining */
  *field = *infield;
  field->flags = flags;
  if (infield->wcs)
    field->wcs = copy_wcs(infield->wcs);
  field->interp_flag = 0;
  field->assoc = NULL;
  field->strip = NULL;
  field->fstrip = NULL;
  field->reffield = infield;
  field->file = NULL;

  return field;
  }


/********************************* endfield **********************************/
/*
Free and close everything related to a field structure.
*/
void	endfield(picstruct *field)

  {

/* Free cat only if associated with an open file */
  if (field->file)
    free_cat(&field->cat, 1);
  free(field->strip);
  free(field->fstrip);
  if (field->wcs)
    end_wcs(field->wcs);
  if (field->interp_flag)
    end_interpolate(field);
  endback(field);
  free(field);

  return;
  }

