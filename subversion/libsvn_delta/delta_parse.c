/*
 * delta_parse.c: create an svn_delta_t from an XML stream
 *
 * ================================================================
 * Copyright (c) 2000 Collab.Net.  All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 * 
 * 1. Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 * 
 * 2. Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 * 
 * 3. The end-user documentation included with the redistribution, if
 * any, must include the following acknowlegement: "This product includes
 * software developed by Collab.Net (http://www.Collab.Net/)."
 * Alternately, this acknowlegement may appear in the software itself, if
 * and wherever such third-party acknowlegements normally appear.
 * 
 * 4. The hosted project names must not be used to endorse or promote
 * products derived from this software without prior written
 * permission. For written permission, please contact info@collab.net.
 * 
 * 5. Products derived from this software may not use the "Tigris" name
 * nor may "Tigris" appear in their names without prior written
 * permission of Collab.Net.
 * 
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESSED OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL COLLAB.NET OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
 * GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
 * IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * ====================================================================
 * 
 * This software consists of voluntary contributions made by many
 * individuals on behalf of Collab.Net.
 */

/* ==================================================================== */


/*
  This library contains callbacks to use with the "expat-lite" XML
  parser.  The callbacks produce an svn_delta_t structure from a
  stream containing Subversion's XML delta representation.

  To use this library, see "deltaparse-test.c" in tests/.
  
  Essentially, one must 
  
  * create an XML_Parser
  * register the callbacks (below) with the parser
  * call XML_Parse() on a bytestream
  
*/

#include "delta_parse.h"




/* Constructor, for factorizing code */
svn_edit_t * 
svn_create_edit (apr_pool_t *pool, svn_XML_elt_t action, char **atts)
{
  /* TODO:  fill in fields from atts */
  svn_edit_t *new_edit = apr_pcalloc (pool, sizeof (svn_edit_t *));
  
}



/* Recursively walk down delta D.  (PARENT is used for recursion purposes.)

   Return the bottommost object in BOTTOM_OBJ and BOTTOM_KIND.
      (Needed later for appending objects to the delta.)

   The penultimate object is returned in PENULT_OBJ and PENULT_KIND. 
      (Needed later for removing objects from the delta.)
*/

void
svn_find_delta_bottom (void **bottom_obj,
                       svn_XML_elt_t *bottom_kind, 
                       void **penult_obj,
                       svn_XML_elt_t *penult_kind,
                       svn_delta_t *d,
                       void *parent)
{
  svn_edit_t *current_edit = d->edit;

  /* Start at top-level tree-delta */
  if (current_edit == NULL)
    {
      *bottom_obj = d;
      *bottom_kind = svn_XML_treedelta;
      *penult_obj = parent;
      *penult_kind = svn_XML_editcontent;
      return;
    }

  else  /* ...go deeper. */
    {
      /* Look at edit struct inside the tree-delta */
      svn_edit_content_t *current_content = current_edit->content;

      if (current_content == NULL)
        {
          *bottom_obj = current_edit;
          *bottom_kind = svn_XML_edit;
          *penult_obj = d;
          *penult_kind = svn_XML_treedelta;
          return;
        }

      else  /* ...go deeper. */
        {
          /* Look inside the content object */
          if (current_content->tree_delta == NULL)
            {
              *bottom_obj = current_content;
              *bottom_kind = svn_XML_editcontent;
              *penult_obj = current_edit;
              *penult_kind = svn_XML_edit;
              return;
            }

          else  /* ... go deeper. */
            {
              /* Since this edit_content already contains a
                 tree-delta, we better RECURSE to continue our search!  */
              svn_find_delta_bottom (bottom_obj, bottom_kind,
                                     penult_obj, penult_kind,
                                     d,
                                     current_content->tree_delta);
              return;
            }
        }
    }
}





/* 
   svn_starpend_delta() : either (ap)pend or (un)pend an object to the
                          end of a delta.  

   (Feel free to think of a better name: svn_telescope_delta() ?) :)

   Append or remove OBJECT to/from the end of delta D.  

   ELT_KIND defines which kind of object is being appended or removed.

   Use DESTROY-P to toggle append/remove behavior.  (When destroying,
   OBJECT will be ignored -- only ELT_KIND matters.)

*/

svn_error_t *
svn_starpend_delta (svn_delta_digger_t *digger,
                    void *object,
                    svn_XML_elt_t elt_kind,
                    svn_boolean_t destroy-p)
{
  void *bottom_ptr, *penult_ptr;
  svn_XML_elt_t bottom_kind, penult_kind;
  svn_delta_t *d = digger->delta;

  /* Get a grip on the last two objects in the delta (by cdr'ing down) */
  svn_find_delta_bottom (&bottom_ptr, &bottom_kind, 
                         &penult_ptr, &penult_kind, 
                         d);

  /* Sanity-check: if we're destroying the last object in the delta,
     then we should check that ELT_KIND (sent from the caller) and
     BOTTOM_KIND match!  */
  if (destroy_p && (elt_kind != bottom_kind))
    {
      return 
        svn_create_error 
        (SVN_ERR_MALFORMED_XML, NULL,
         "caller thinks delta's bottom object type is different that it is!"
         NULL, digger->pool);
    }

  switch (bottom_kind)
    {
    case (svn_XML_treedelta):  
      {
        if (destroy_p)
          {
            svn_edit_content_t *ec = (svn_edit_content_t *) penult_ptr;
            ec->tree_delta = NULL;
            return SVN_NO_ERROR;
          }
        else /* appending */
          {
            /* Bottom object is a tree-delta */
            svn_delta_t *this_delta = (svn_delta_t *) bottom_ptr;

            /* If bottom_ptr is a treedelta, then we must be appending an
               svn_edit_t.  Sanity check.  */
            if (elt_kind != svn_XML_edit)
              return svn_create_error (SVN_ERR_MALFORMED_XML, NULL,
                                       "expecting to append svn_edit_t, not found!",
                                       NULL, digger->pool);

            this_delta->edit = (svn_edit_t *) object;
            return SVN_NO_ERROR;
          }
        
      }

    case (svn_XML_edit):
      {
        if (destroy_p)
          {
            svn_delta_t *dl = (svn_delta_t *) penult_ptr;
            dl->edit = NULL;
            return SVN_NO_ERROR;
          }
        else /* appending */
          {
            /* Bottom object is an edit */
            svn_edit_t *this_edit = (svn_edit_t *) bottom_ptr;

            /* If bottom_ptr is an edit, then we must be appending an
               svn_edit_content_t.  Sanity check.  */
            if (elt_kind != svn_XML_editcontent)
              return svn_create_error (SVN_ERR_MALFORMED_XML, NULL,
                                       "expecting to append svn_edit_content_t, not found!",
                                       NULL, digger->pool);

            this_edit->content = (svn_edit_content_t *) object;
            return SVN_NO_ERROR;
          }
      }

    case (svn_XML_editcontent):
      {
        if (destroy_p)
          {
            svn_edit_t *ed = (svn_edit_t *) penult_ptr;
            ed->content = NULL;
            return SVN_NO_ERROR;
          }
        else  /* appending */ 
          {
            /* If bottom_ptr is an edit_content, then we must be appending
               one of three kinds of objects.  Examine ELT_KIND. */
            svn_edit_content_t *this_content 
              = (svn_edit_content_t *) bottom_ptr;
            
            switch (elt_kind)
              {
              case svn_XML_propdelta:
                {
                  this_content->prop_delta = TRUE;
                  return SVN_NO_ERROR;
                }
              case svn_XML_textdelta:
                {
                  this_content->text_delta = TRUE;
                  return SVN_NO_ERROR;
                }
              case svn_XML_treedelta:
                {
                  this_content->tree_delta = (svn_delta_t *) object;
                  return SVN_NO_ERROR;
                }
              default:
                {
                  return 
                    svn_create_error (SVN_ERR_MALFORMED_XML, NULL,
                                      "found something other than pdelta, vdelta, or textdelta to append.",
                                      NULL, digger->pool);
                }
              }
          }
      }

    default:
      {
        return svn_create_error (SVN_ERR_MALFORMED_XML, NULL,
                                 "unrecognized svn_XML_elt type.",
                                 NULL, digger->pool);
      }
    }
}






/* Callback:  called whenever we find a new tag (open paren).

    The *name argument contains the name of the tag,
    and the **atts list is a dumb list of name/value pairs, all
    null-terminated Cstrings, and ending with an extra final NULL.

*/  
      
void
svn_xml_handle_start (void *userData, const char *name, const char **atts)
{
  int i;
  char *attr_name, *attr_value;

  /* Retrieve our digger structure */
  svn_delta_digger_t *my_digger = (svn_delta_digger_t *) userData;

  /* Match the new tag's name to one of Subversion's XML tags... */

  if (strcmp (name, "tree-delta") == 0)
    {
      /* Found a new tree-delta element */

      /* Create new svn_delta_t structure here, filling in attributes */
      svn_delta_t *new_delta = apr_pcalloc (my_digger->pool, 
                                            sizeof (svn_delta_t *));

      /* TODO: <tree-delta> doesn't take any attributes right now, but
         our svn_delta_t structure still has src_root and base_ver
         fields.  Is this bad? */

      if (my_digger->delta == NULL)
        {
          /* This is the very FIRST element of our tree delta! */
          my_digger->delta = new_delta;
          return;
        }
      else
        {
          /* This is a nested tree-delta, below a <dir>.  Hook it in. */
          svn_error_t *err = 
            svn_starpend_delta (my_digger, new_delta, 
                                svn_XML_treedelta, FALSE);

          /* TODO: we're inside an event-driven callback.  What do we
             do if we get an error?  Just Punt?  Call a warning
             callback?  Perhaps we should have an error_handler()
             inside our digger structure!  Does Expat have a
             mechanism, or do we need to longjump out? */
        }
    }

  else if (strcmp (name, "text-delta") == 0)
    {
      /* Found a new text-delta element */
      /* No need to create a text-delta structure... */
      /* TODO: ...just mark flag in edit_content structure (should be the
         last structure on our growing delta) */

    }

  else if (strcmp (name, "prop-delta") == 0)
    {
      /* Found a new prop-delta element */
      /* No need to create a prop-delta structure... */
      /* TODO: ...just mark flag in edit_content structure (should be the
         last structure on our growing delta) */
    }

  else if (strcmp (name, "new") == 0)
    {
      svn_error_t *err;
      /* Found a new svn_edit_t */
      /* Build a new edit struct */

      svn_edit_t *new_edit = svn_create_edit (my_digger->pool,
                                              action_new, 
                                              atts);

      err = svn_starpend_delta (my_digger, new_edit, svn_XML_edit, FALSE);

      /* TODO: check error */
    }

  else if (strcmp (name, "replace"))
    {
      svn_error_t *err;
      /* Found a new svn_edit_t */
      /* Build a new edit struct */
      svn_edit_t *new_edit = apr_pcalloc (my_digger->pool, 
                                          sizeof (svn_edit_t *));

      new_edit->kind = action_replace;

      /* Our three edit tags currently only have one attribute: "name" */
      if (strcmp (*atts, "name") == 0) {
        new_edit->name = svn_string_create (++*atts, my_digger->pool);
      }
      else {
        /* TODO: return error if we have some other attribute */
      }

      /* Now drop this edit at the end of our delta */
      err = svn_append_to_delta (my_digger->delta,
                                 new_edit,
                                 svn_XML_edit);
      /* TODO: check error */

    }

  else if (strcmp (name, "delete"))
    {
      svn_error_t *err;
      /* Found a new svn_edit_t */
      /* Build a new edit struct */
      svn_edit_t *new_edit = apr_pcalloc (my_digger->pool, 
                                          sizeof (svn_edit_t *));
      new_edit->kind = action_delete;

      /* Our three edit tags currently only have one attribute: "name" */
      if (strcmp (*atts, "name") == 0) {
        new_edit->name = svn_string_create (++*atts, my_digger->pool);
      }
      else {
        /* TODO: return error if we have some other attribute */
      }

      /* Now drop this edit at the end of our delta */
      err = svn_append_to_delta (my_digger->delta,
                                 new_edit,
                                 svn_XML_edit);
      /* TODO: check error */

    }

  else if (strcmp (name, "file"))
    {
      svn_error_t *err;
      /* Found a new svn_edit_content_t */
      /* Build a edit_content_t */
      svn_edit_content_t *this_edit_content 
        = apr_pcalloc (my_digger->pool, 
                       sizeof (svn_edit_content_t *));

      this_edit_content->kind = file_type;
      
      /* Build an ancestor object out of **atts */
      while (*atts)
        {
          char *attr_name = *atts++;
          char *attr_value = *atts++;

          if (strcmp (attr_name, "ancestor") == 0)
            {
              this_edit_content->ancestor_path
                = svn_string_create (attr_value, my_digger->pool);
            }
          else if (strcmp (attr_name, "ver") == 0)
            {
              this_edit_content->ancestor_version = atoi (attr_value);
            }
          else if (strcmp (attr_name, "new") == 0)
            {
              /* Do nothing, because ancestor_path is already set to
                 NULL, which indicates a new entity. */
            }
          else
            {
              /* TODO: unknown tag attribute, return error */
            }
        }

      /* Drop the edit_content object on the end of the delta */
      err = svn_append_to_delta (my_digger->delta,
                                 this_edit_content,
                                 svn_XML_editcontent);

      /* TODO:  check for error */
    }

  else if (strcmp (name, "dir"))
    {
      svn_error_t *err;
      /* Found a new svn_edit_content_t */
      /* Build a edit_content_t */
      svn_edit_content_t *this_edit_content 
        = apr_pcalloc (my_digger->pool, 
                       sizeof (svn_edit_content_t *));

      this_edit_content->kind = directory_type;
      
      /* Build an ancestor object out of **atts */
      while (*atts)
        {
          char *attr_name = *atts++;
          char *attr_value = *atts++;

          if (strcmp (attr_name, "ancestor") == 0)
            {
              this_edit_content->ancestor_path
                = svn_string_create (attr_value, my_digger->pool);
            }
          else if (strcmp (attr_name, "ver") == 0)
            {
              this_edit_content->ancestor_version = atoi(attr_value);
            }
          else if (strcmp (attr_name, "new") == 0)
            {
              /* Do nothing, because NULL ancestor_path indicates a
                 new entity. */
            }
          else
            {
              /* TODO: unknown tag attribute, return error */
            }
        }

      /* Drop the edit_content object on the end of the delta */
      err = svn_append_to_delta (my_digger->delta,
                                 this_edit_content,
                                 svn_XML_editcontent);

      /* TODO:  check for error */

      /* Call the "directory" callback in the digger struct; this
         allows the client to possibly create new subdirs on-the-fly,
         for example. */
      err = (* (my_digger->dir_handler)) (my_digger, this_edit_content);

      /* TODO: check for error */
    }

  else
    {
      svn_error_t *err;
      /* Found some unrecognized tag, so PUNT to the caller's
         default handler. */
      err = (* (my_digger->unknown_elt_handler)) (my_digger, name, atts);

      /* TODO: check for error */
    }
}






/*  Callback:  called whenever we find a close tag (close paren) */

void svn_xml_handle_end (void *userData, const char *name)
{
  svn_error_t *err;
  svn_delta_digger_t *my_digger = (svn_delta_digger_t *) userData;

  
  /* First, figure out what kind of element is being "closed" in our
     XML stream */

  if (strcmp (name, "tree-delta") == 0)
    {
      /* Snip the now-closed tree off the delta. */
      err = svn_starpend_delta (my_digger, NULL, svn_XML_treedelta, TRUE);
    }

  else if (strcmp (name, "text-delta") == 0)
    {
      /* TODO */
      /* bottomost object of delta should be an edit_content_t,
         so we unset it's text_delta flag here. */
    }

  else if (strcmp (name, "prop-delta") == 0)
    {
      /* TODO */
      /* bottomost object of delta should be an edit_content_t,
         so we unset it's prop_delta flag here. */
    }

  else if ((strcmp (name, "new") == 0) 
           || (strcmp (name, "replace") == 0)
           || (strcmp (name, "delete") == 0))
    {
      /* Snip the now-closed edit_t off the delta. */
      err = svn_starpend_delta (my_digger, NULL, svn_XML_edit, TRUE);
    }

  else if ((strcmp (name, "file") == 0)
           || (strcmp (name, "dir") == 0))
    {
      /* Snip the now-closed edit_content_t off the delta. */
      err = svn_starpend_delta (my_digger, NULL, svn_XML_editcontent, TRUE);
    }

  else  /* default */
    {
      /* Found some unrecognized tag, so PUNT to the caller's
         default handler. */
      err = (* (my_digger->unknown_elt_handler)) (my_digger, name, atts);
    }

  /* TODO: what to do with a potentially returned
     SVN_ERR_MALFORMED_XML at this point?  Do we need to longjump out
     of expat's callback, or does expat have a error system? */  
}



/* Callback: called whenever we find data within a tag.  
   (Of course, we only care about data within the "text-delta" tag.)  */

void svn_xml_handle_data (void *userData, const char *data, int len)
{
  svn_delta_digger_t *my_digger = (svn_delta_digger_t *) userData;

  /* TODO: Check context of my_digger->delta, make sure that *data is
     relevant before we bother our data_handler() */

  /* TODO: see note about data handler context optimization in
     svn_delta.h:svn_delta_digger_t. */

  (* (my_digger->data_handler)) (my_digger, data, len);

}



XML_Parser
svn_delta_make_xml_parser (svn_delta_digger_t *diggy)
{
  /* Create the parser */
  XML_Parser parser = XML_ParserCreate (NULL);

  /* All callbacks should receive the delta_digger structure. */
  XML_SetUserData (parser, diggy);

  /* Register subversion-specific callbacks with the parser */
  XML_SetElementHandler (parser,
                         svn_xml_handle_start,
                         svn_xml_handle_end); 
  XML_SetCharacterDataHandler (parser, svn_xml_handle_data);

  return parser;
}



/* 
 * local variables:
 * eval: (load-file "../svn-dev.el")
 * end:
 */
