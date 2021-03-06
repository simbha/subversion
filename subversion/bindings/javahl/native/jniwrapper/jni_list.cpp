/**
 * @copyright
 * ====================================================================
 *    Licensed to the Apache Software Foundation (ASF) under one
 *    or more contributor license agreements.  See the NOTICE file
 *    distributed with this work for additional information
 *    regarding copyright ownership.  The ASF licenses this file
 *    to you under the Apache License, Version 2.0 (the
 *    "License"); you may not use this file except in compliance
 *    with the License.  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing,
 *    software distributed under the License is distributed on an
 *    "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 *    KIND, either express or implied.  See the License for the
 *    specific language governing permissions and limitations
 *    under the License.
 * ====================================================================
 * @endcopyright
 */

#include "jni_list.hpp"

namespace Java {

// Class Java::BaseList

const char* const BaseList::m_class_name = "java/util/List";

MethodID BaseList::m_mid_size;
MethodID BaseList::m_mid_get;

void BaseList::static_init(Env env)
{
  const jclass cls = ClassCache::get_list();
  m_mid_size = env.GetMethodID(cls, "size", "()I");
  m_mid_get = env.GetMethodID(cls, "get", "(I)Ljava/lang/Object;");
}

BaseList::ovector
BaseList::convert_to_vector(Env env, jobject jlist)
{
  const jint length = env.CallIntMethod(jlist, m_mid_size);

  if (!length)
    return ovector();

  ovector contents(length);
  ovector::iterator it;
  jint i;
  for (i = 0, it = contents.begin(); it != contents.end(); ++it, ++i)
    *it = env.CallObjectMethod(jlist, m_mid_get, i);
  return contents;
}


// Class Java::BaseMutableList

const char* const BaseMutableList::m_class_name = "java/util/ArrayList";

MethodID BaseMutableList::m_mid_ctor;
MethodID BaseMutableList::m_mid_add;
MethodID BaseMutableList::m_mid_clear;
MethodID BaseMutableList::m_mid_get;
MethodID BaseMutableList::m_mid_size;

void BaseMutableList::static_init(Env env)
{
  const jclass cls = ClassCache::get_array_list();
  m_mid_ctor = env.GetMethodID(cls, "<init>", "(I)V");
  m_mid_add = env.GetMethodID(cls, "add", "(Ljava/lang/Object;)Z");
  m_mid_clear = env.GetMethodID(cls, "clear", "()V");
  m_mid_get = env.GetMethodID(cls, "get", "(I)Ljava/lang/Object;");
  m_mid_size = env.GetMethodID(cls, "size", "()I");
}

} // namespace Java
