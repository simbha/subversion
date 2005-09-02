/*
 * intl-test.c:  tests svn_intl
 *
 * ====================================================================
 * Copyright (c) 2005 CollabNet.  All rights reserved.
 *
 * This software is licensed as described in the file COPYING, which
 * you should have received as part of this distribution.  The terms
 * are also available at http://subversion.tigris.org/license-1.html.
 * If newer versions of this license are posted there, you may use a
 * newer version instead, at your option.
 *
 * This software consists of voluntary contributions made by many
 * individuals.  For exact contribution history, see the revision
 * history and logs, available at http://subversion.tigris.org/.
 * ====================================================================
 */

/* ====================================================================
   To add tests, look toward the bottom of this file.

*/



#include <string.h>

#include <apr_getopt.h>
#ifdef PO_BUNDLES_FROM_SRC_DIR_USABLE  /* Sadly, they don't seem to be. */
#include <apr_file_info.h>
#endif
#include <apr_pools.h>
#include <apr_tables.h>

#include "svn_error.h"
#include "svn_pools.h"
#include "svn_types.h"
#include "svn_intl.h"

#include "../svn_test.h"
#include "svn_private_config.h" /* for PACKAGE_NAME */


/* Initialize parameters for the tests. */
extern int test_argc;
extern const char **test_argv;

static const apr_getopt_option_t opt_def[] =
  {
    {"srcdir", 'S', 1, "the source directory for VPATH test runs"},
    {"verbose", 'v', 0, "print extra information"},
    {0, 0, 0, 0}
  };
static const char *srcdir = NULL;
static svn_boolean_t verbose_mode = FALSE;

static svn_error_t *init_params (apr_pool_t *pool)
{
  apr_getopt_t *opt;
  int optch;
  const char *opt_arg;
  apr_status_t status;
#ifdef PO_BUNDLES_FROM_SRC_DIR_USABLE
  char *gettext_path;
#endif

  apr_getopt_init (&opt, pool, test_argc, test_argv);
  while (!(status = apr_getopt_long (opt, opt_def, &optch, &opt_arg)))
    {
      switch (optch)
        {
        case 'S':
          srcdir = opt_arg;
          break;
        case 'v':
          verbose_mode = TRUE;
          break;
        }
    }

#ifdef PO_BUNDLES_FROM_SRC_DIR_USABLE
  if (!srcdir)
    return svn_error_create(SVN_ERR_TEST_FAILED, 0,
                            "missing required parameter '--srcdir'");

  /* Setup paths to our localization bundles from the source dir.
     Ideally, we'd point this to the subversion/po/ dir, but
     bindtextdomain expects a very specific directory structure. */
  apr_filepath_merge(&gettext_path, install_dir, "share", 0, pool);
  apr_filepath_merge(&gettext_path, gettext_path, "locale", 0, pool);
  printf("Path used by gettext is '%s'\n", gettext_path);
  if (bindtextdomain(PACKAGE_NAME, gettext_path) == NULL)
    {
      /* ### Handle error as in libsvn_subr/cmdline.c */
    }
#endif

  return SVN_NO_ERROR;
}

/* A quick way to create error messages.  */
static svn_error_t *
fail (apr_pool_t *pool, const char *fmt, ...)
{
  va_list ap;
  char *msg;

  va_start(ap, fmt);
  msg = apr_pvsprintf(pool, fmt, ap);
  va_end(ap);

  return svn_error_create (SVN_ERR_TEST_FAILED, 0, msg);
}

typedef struct
{
  const char *key;
  const char *value;
  const char *locale;
} l10n_t;

static l10n_t l10n_list[] =
  {
    { "Could not save file", "No se pudo grabar el archivo", "es" },
    { "Error writing to '%s'", "Error escribiendo en '%s'", "es" },
    { NULL, 0 }
  };

static const char *LOCALE_PREFS[] = { "es_ES", "en_US" };

/* Helper which initializes an apr_array_header_t to contain
   LOCALE_PREFS. */
static void
init_user_locale_prefs (apr_array_header_t **user_prefs, apr_pool_t *p)
{
  int i;
  *user_prefs = apr_array_make (p, 2, sizeof (*LOCALE_PREFS));
  for (i = 0; i < 2; i++)
    APR_ARRAY_PUSH (*user_prefs, const char *) = LOCALE_PREFS[i];
}

static svn_error_t *
test1 (const char **msg, 
       svn_boolean_t msg_only,
       svn_test_opts_t *opts,
       apr_pool_t *pool)
{
  svn_error_t *err;
  apr_array_header_t *locale_prefs;

  *msg = "test locale preference retrieval of svn_intl";

  if (msg_only)
    return SVN_NO_ERROR;

  if (!srcdir)
    SVN_ERR(init_params(pool));

  err = svn_intl_initialize(pool);
  if (err)
    {
      return svn_error_create (SVN_ERR_TEST_FAILED, err,
                               "svn_intl_initialize failed");
    }

  svn_intl_get_locale_prefs(&locale_prefs, pool);
  if (locale_prefs == NULL)
    {
      /* This should never happen. */
      return fail(pool, "svn_intl_get_locale_prefs should never "
                  "return NULL, but did: setlocale() failed?");
    }
  else if (verbose_mode)
    {
      if (apr_is_empty_table (locale_prefs))
        printf("Locale not recorded in .po file\n");
      else
        printf("Process locale is '%s'\n",
               APR_ARRAY_IDX(locale_prefs, 0, char *));
    }

  /* ### Set some contextual prefs and try again. */

  return SVN_NO_ERROR;
}


/* ### Test re-initialization after sub-pool passed to
   ### svn_intl_initialize() is destroyed. */


static svn_error_t *
test2 (const char **msg, 
       svn_boolean_t msg_only,
       svn_test_opts_t *opts,
       apr_pool_t *pool)
{
  l10n_t *l10n;
  svn_error_t *err;
  apr_pool_t *subpool;

  *msg = "test basic localization using svn_intl";

  if (msg_only)
    return SVN_NO_ERROR;

  if (!srcdir)
    SVN_ERR(init_params(pool));

  subpool = svn_pool_create(pool);
  err = svn_intl_initialize(subpool);
  if (err)
    {
      return svn_error_create (SVN_ERR_TEST_FAILED, err,
                               "svn_intl_initialize failed");
    }

  /* Test retrieval of localizations using our svn_intl module. */
  for (l10n = l10n_list; l10n->key != NULL; l10n++)
    {
      /* ### Account for a not-yet-installed resource bundle by using
         ### srcdir instead of SVN_LOCALE_DIR to remove XFAIL. */

      /* ### Test that svn_intl_dgettext(PACKAGE_NAME, l10n->key)
         ### returns the key when in "en" locale, or lang not
         ### available. */

      const char *intl_value = svn_intl_dlgettext (PACKAGE_NAME, l10n->locale,
                                                   l10n->key);
      if ((l10n->value == NULL) != (intl_value == NULL)
          || (l10n->value != NULL && intl_value != NULL
              && strcmp (l10n->value, intl_value) != 0))
        return fail(pool, "Expected value '%s' not equal to '%s' for "
                    "text '%s'", l10n->value, intl_value, l10n->key);
    }

  apr_pool_destroy(subpool);

  return SVN_NO_ERROR;
}



static svn_error_t *
test3 (const char **msg, 
       svn_boolean_t msg_only,
       svn_test_opts_t *opts,
       apr_pool_t *pool)
{
  l10n_t *l10n;
  svn_error_t *err;
  apr_array_header_t *user_prefs;
  apr_array_header_t *prefs;
  int i;

  *msg = "test storage of user locale prefs using svn_intl";

  if (msg_only)
    return SVN_NO_ERROR;

  err = svn_intl_initialize(pool);
  if (err)
    {
      return svn_error_create (SVN_ERR_TEST_FAILED, err,
                               "svn_intl_initialize failed");
    }

  init_user_locale_prefs (&user_prefs, pool);

  if (verbose_mode)
    {
      int i;
      printf ("Setting locale preferences: ");
      for (i = 0; i < user_prefs->nelts; i++)
        printf ("%s ", APR_ARRAY_IDX (user_prefs, i, char *));
      printf ("\n");
    }
  svn_intl_set_locale_prefs (user_prefs, pool);
  svn_intl_get_locale_prefs (&prefs, pool);
  for (i = 0; i < prefs->nelts; i++)
    {
      if (verbose_mode)
        printf ("Comparing expected locale pref '%s' to contextual pref "
                "'%s'\n", APR_ARRAY_IDX (user_prefs, i, char *),
                APR_ARRAY_IDX (prefs, i, char *));

      if (strcmp (APR_ARRAY_IDX (prefs, i, char *),
                  APR_ARRAY_IDX (user_prefs, i, char *)) != 0)
        return fail (pool, "Expected locale pref '%s' not equal to "
                     "contextual pref '%s'",
                     APR_ARRAY_IDX (user_prefs, i, char *),
                     APR_ARRAY_IDX (prefs, i, char *));
    }

  /* Test retrieval of localizations using our svn_intl module.
  for (l10n = l10n_list; l10n->key != NULL; l10n++)
    {
      const char *intl_value = svn_intl_dlgettext (PACKAGE_NAME, l10n->locale,
                                                   l10n->key);
      if ((l10n->value == NULL) != (intl_value == NULL)
          || (l10n->value != NULL && intl_value != NULL
              && strcmp (l10n->value, intl_value) != 0))
        return fail(pool, "Expected value '%s' not equal to '%s' for "
                    "text '%s'", l10n->value, intl_value, l10n->key);
    }
  */

  return SVN_NO_ERROR;
}


/*
   ====================================================================
   If you add a new test to this file, update this array.

   (These globals are required by our included main())
*/

/* An array of all test functions */
struct svn_test_descriptor_t test_funcs[] =
  {
    SVN_TEST_NULL,
    /* ### XFAIL is a work-around for not-yet-installed bundles. */
    SVN_TEST_XFAIL (test1),
    SVN_TEST_PASS (test2),
    SVN_TEST_PASS (test3),
    SVN_TEST_NULL
  };
