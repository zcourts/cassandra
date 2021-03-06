/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

grammar Cql;

options {
    language = Java;
}

@header {
    package org.apache.cassandra.cql3;

    import java.util.ArrayList;
    import java.util.Arrays;
    import java.util.Collections;
    import java.util.HashMap;
    import java.util.LinkedHashMap;
    import java.util.List;
    import java.util.Map;

    import org.apache.cassandra.cql3.operations.*;
    import org.apache.cassandra.auth.Permission;
    import org.apache.cassandra.cql3.statements.*;
    import org.apache.cassandra.db.marshal.CollectionType;
    import org.apache.cassandra.exceptions.ConfigurationException;
    import org.apache.cassandra.exceptions.InvalidRequestException;
    import org.apache.cassandra.exceptions.SyntaxException;
    import org.apache.cassandra.utils.Pair;
}

@members {
    private List<String> recognitionErrors = new ArrayList<String>();
    private int currentBindMarkerIdx = -1;

    public void displayRecognitionError(String[] tokenNames, RecognitionException e)
    {
        String hdr = getErrorHeader(e);
        String msg = getErrorMessage(e, tokenNames);
        recognitionErrors.add(hdr + " " + msg);
    }

    public void addRecognitionError(String msg)
    {
        recognitionErrors.add(msg);
    }

    public List<String> getRecognitionErrors()
    {
        return recognitionErrors;
    }

    public void throwLastRecognitionError() throws SyntaxException
    {
        if (recognitionErrors.size() > 0)
            throw new SyntaxException(recognitionErrors.get((recognitionErrors.size()-1)));
    }

    // used by UPDATE of the counter columns to validate if '-' was supplied by user
    public void validateMinusSupplied(Object op, final Term value, IntStream stream) throws MissingTokenException
    {
        if (op == null && (value.isBindMarker() || Long.parseLong(value.getText()) > 0))
            throw new MissingTokenException(102, stream, value);
    }

    public Map<String, String> convertMap(Map<Term, Term> terms)
    {
        if (terms == null || terms.isEmpty())
            return Collections.<String, String>emptyMap();

        Map<String, String> res = new HashMap<String, String>(terms.size());

        for (Map.Entry<Term, Term> entry : terms.entrySet())
        {
            // Because the parser tries to be smart and recover on error (to
            // allow displaying more than one error I suppose), we have null
            // entries in there. Just skip those, a proper error will be thrown in the end.
            if (entry.getKey() == null || entry.getValue() == null)
                break;
            res.put(entry.getKey().getText(), entry.getValue().getText());
        }

        return res;
    }
}

@lexer::header {
    package org.apache.cassandra.cql3;

    import org.apache.cassandra.exceptions.SyntaxException;
}

@lexer::members {
    List<Token> tokens = new ArrayList<Token>();

    public void emit(Token token)
    {
        state.token = token;
        tokens.add(token);
    }

    public Token nextToken()
    {
        super.nextToken();
        if (tokens.size() == 0)
            return Token.EOF_TOKEN;
        return tokens.remove(0);
    }

    private List<String> recognitionErrors = new ArrayList<String>();

    public void displayRecognitionError(String[] tokenNames, RecognitionException e)
    {
        String hdr = getErrorHeader(e);
        String msg = getErrorMessage(e, tokenNames);
        recognitionErrors.add(hdr + " " + msg);
    }

    public List<String> getRecognitionErrors()
    {
        return recognitionErrors;
    }

    public void throwLastRecognitionError() throws SyntaxException
    {
        if (recognitionErrors.size() > 0)
            throw new SyntaxException(recognitionErrors.get((recognitionErrors.size()-1)));
    }
}

/** STATEMENTS **/

query returns [ParsedStatement stmnt]
    : st=cqlStatement (';')* EOF { $stmnt = st; }
    ;

cqlStatement returns [ParsedStatement stmt]
    @after{ if (stmt != null) stmt.setBoundTerms(currentBindMarkerIdx + 1); }
    : st1= selectStatement             { $stmt = st1; }
    | st2= insertStatement             { $stmt = st2; }
    | st3= updateStatement             { $stmt = st3; }
    | st4= batchStatement              { $stmt = st4; }
    | st5= deleteStatement             { $stmt = st5; }
    | st6= useStatement                { $stmt = st6; }
    | st7= truncateStatement           { $stmt = st7; }
    | st8= createKeyspaceStatement     { $stmt = st8; }
    | st9= createColumnFamilyStatement { $stmt = st9; }
    | st10=createIndexStatement        { $stmt = st10; }
    | st11=dropKeyspaceStatement       { $stmt = st11; }
    | st12=dropColumnFamilyStatement   { $stmt = st12; }
    | st13=dropIndexStatement          { $stmt = st13; }
    | st14=alterTableStatement         { $stmt = st14; }
    | st15=grantStatement              { $stmt = st15; }
    | st16=revokeStatement             { $stmt = st16; }
    | st17=listGrantsStatement         { $stmt = st17; }
    | st18=alterKeyspaceStatement      { $stmt = st18; }
    ;

/*
 * USE <KEYSPACE>;
 */
useStatement returns [UseStatement stmt]
    : K_USE ks=keyspaceName { $stmt = new UseStatement(ks); }
    ;

/**
 * SELECT <expression>
 * FROM <CF>
 * USING CONSISTENCY <LEVEL>
 * WHERE KEY = "key1" AND COL > 1 AND COL < 100
 * LIMIT <NUMBER>;
 */
selectStatement returns [SelectStatement.RawStatement expr]
    @init {
        boolean isCount = false;
        int limit = 10000;
        Map<ColumnIdentifier, Boolean> orderings = new LinkedHashMap<ColumnIdentifier, Boolean>();
    }
    : K_SELECT ( sclause=selectClause | (K_COUNT '(' sclause=selectCountClause ')' { isCount = true; }) )
      K_FROM cf=columnFamilyName
      ( K_WHERE wclause=whereClause )?
      ( K_ORDER K_BY orderByClause[orderings] ( ',' orderByClause[orderings] )* )?
      ( K_LIMIT rows=INTEGER { limit = Integer.parseInt($rows.text); } )?
      {
          SelectStatement.Parameters params = new SelectStatement.Parameters(limit,
                                                                             orderings,
                                                                             isCount);
          $expr = new SelectStatement.RawStatement(cf, params, sclause, wclause);
      }
    ;

selectClause returns [List<Selector> expr]
    : t1=selector { $expr = new ArrayList<Selector>(); $expr.add(t1); } (',' tN=selector { $expr.add(tN); })*
    | '\*' { $expr = Collections.<Selector>emptyList();}
    ;

selector returns [Selector s]
    : c=cident             { $s = c; }
    | K_WRITETIME '(' c=cident ')' { $s = new Selector.WithFunction(c, Selector.Function.WRITE_TIME); }
    | K_TTL '(' c=cident ')'       { $s = new Selector.WithFunction(c, Selector.Function.TTL); }
    ;

selectCountClause returns [List<Selector> expr]
    : '\*'           { $expr = Collections.<Selector>emptyList();}
    | i=INTEGER      { if (!i.getText().equals("1")) addRecognitionError("Only COUNT(1) is supported, got COUNT(" + i.getText() + ")"); $expr = Collections.<Selector>emptyList();}
    ;

whereClause returns [List<Relation> clause]
    @init{ $clause = new ArrayList<Relation>(); }
    : relation[$clause] (K_AND relation[$clause])*
    ;

orderByClause[Map<ColumnIdentifier, Boolean> orderings]
    @init{
        ColumnIdentifier orderBy = null;
        boolean reversed = false;
    }
    : c=cident { orderBy = c; } (K_ASC | K_DESC { reversed = true; })? { orderings.put(c, reversed); }
    ;

/**
 * INSERT INTO <CF> (<column>, <column>, <column>, ...)
 * VALUES (<value>, <value>, <value>, ...)
 * USING TIMESTAMP <long>;
 *
 */
insertStatement returns [UpdateStatement expr]
    @init {
        Attributes attrs = new Attributes();
        List<ColumnIdentifier> columnNames  = new ArrayList<ColumnIdentifier>();
        List<Operation> columnOperations = new ArrayList<Operation>();
    }
    : K_INSERT K_INTO cf=columnFamilyName
          '(' c1=cident { columnNames.add(c1); }  ( ',' cn=cident { columnNames.add(cn); } )+ ')'
        K_VALUES
          '(' v1=set_operation { columnOperations.add(v1); } ( ',' vn=set_operation { columnOperations.add(vn); } )+ ')'
        ( usingClause[attrs] )?
      {
          $expr = new UpdateStatement(cf, attrs, columnNames, columnOperations);
      }
    ;

usingClause[Attributes attrs]
    : K_USING usingClauseObjective[attrs] ( K_AND? usingClauseObjective[attrs] )*
    ;

usingClauseDelete[Attributes attrs]
    : K_USING usingClauseDeleteObjective[attrs] ( K_AND? usingClauseDeleteObjective[attrs] )*
    ;

usingClauseDeleteObjective[Attributes attrs]
    : K_TIMESTAMP ts=INTEGER { attrs.timestamp = Long.valueOf($ts.text); }
    ;

usingClauseObjective[Attributes attrs]
    : usingClauseDeleteObjective[attrs]
    | K_TTL t=INTEGER { attrs.timeToLive = Integer.valueOf($t.text); }
    ;

/**
 * UPDATE <CF>
 * USING CONSISTENCY <level> AND TIMESTAMP <long>
 * SET name1 = value1, name2 = value2
 * WHERE key = value;
 */
updateStatement returns [UpdateStatement expr]
    @init {
        Attributes attrs = new Attributes();
        List<Pair<ColumnIdentifier, Operation>> columns = new ArrayList<Pair<ColumnIdentifier, Operation>>();
    }
    : K_UPDATE cf=columnFamilyName
      ( usingClause[attrs] )?
      K_SET termPairWithOperation[columns] (',' termPairWithOperation[columns])*
      K_WHERE wclause=whereClause
      {
          return new UpdateStatement(cf, columns, wclause, attrs);
      }
    ;

/**
 * DELETE name1, name2
 * FROM <CF>
 * USING CONSISTENCY <level> AND TIMESTAMP <long>
 * WHERE KEY = keyname;
 */
deleteStatement returns [DeleteStatement expr]
    @init {
        Attributes attrs = new Attributes();
        List<Selector> columnsList = Collections.emptyList();
    }
    : K_DELETE ( ids=deleteSelection { columnsList = ids; } )?
      K_FROM cf=columnFamilyName
      ( usingClauseDelete[attrs] )?
      K_WHERE wclause=whereClause
      {
          return new DeleteStatement(cf, columnsList, wclause, attrs);
      }
    ;

deleteSelection returns [List<Selector> expr]
    : t1=deleteSelector { $expr = new ArrayList<Selector>(); $expr.add(t1); } (',' tN=deleteSelector { $expr.add(tN); })*
    ;

deleteSelector returns [Selector s]
    : c=cident                { $s = c; }
    | c=cident '[' t=term ']' { $s = new Selector.WithKey(c, t); }
    ;

/**
 * BEGIN BATCH [USING CONSISTENCY <LVL>]
 *   UPDATE <CF> SET name1 = value1 WHERE KEY = keyname1;
 *   UPDATE <CF> SET name2 = value2 WHERE KEY = keyname2;
 *   UPDATE <CF> SET name3 = value3 WHERE KEY = keyname3;
 *   ...
 * APPLY BATCH
 *
 * OR
 *
 * BEGIN BATCH [USING CONSISTENCY <LVL>]
 *   INSERT INTO <CF> (KEY, <name>) VALUES ('<key>', '<value>');
 *   INSERT INTO <CF> (KEY, <name>) VALUES ('<key>', '<value>');
 *   ...
 * APPLY BATCH
 *
 * OR
 *
 * BEGIN BATCH [USING CONSISTENCY <LVL>]
 *   DELETE name1, name2 FROM <CF> WHERE key = <key>
 *   DELETE name3, name4 FROM <CF> WHERE key = <key>
 *   ...
 * APPLY BATCH
 */
batchStatement returns [BatchStatement expr]
    @init {
        BatchStatement.Type type = BatchStatement.Type.LOGGED;
        List<ModificationStatement> statements = new ArrayList<ModificationStatement>();
        Attributes attrs = new Attributes();
    }
    : K_BEGIN
      ( K_UNLOGGED { type = BatchStatement.Type.UNLOGGED; } | K_COUNTER { type = BatchStatement.Type.COUNTER; } )?
      K_BATCH ( usingClause[attrs] )?
          s1=batchStatementObjective ';'? { statements.add(s1); } ( sN=batchStatementObjective ';'? { statements.add(sN); } )*
      K_APPLY K_BATCH
      {
          return new BatchStatement(type, statements, attrs);
      }
    ;

batchStatementObjective returns [ModificationStatement statement]
    : i=insertStatement  { $statement = i; }
    | u=updateStatement  { $statement = u; }
    | d=deleteStatement  { $statement = d; }
    ;

/**
 * CREATE KEYSPACE <KEYSPACE> WITH attr1 = value1 AND attr2 = value2;
 */
createKeyspaceStatement returns [CreateKeyspaceStatement expr]
    @init { KSPropDefs attrs = new KSPropDefs(); }
    : K_CREATE K_KEYSPACE ks=keyspaceName
      K_WITH properties[attrs] { $expr = new CreateKeyspaceStatement(ks, attrs); }
    ;

/**
 * CREATE COLUMNFAMILY <CF> (
 *     <name1> <type>,
 *     <name2> <type>,
 *     <name3> <type>
 * ) WITH <property> = <value> AND ...;
 */
createColumnFamilyStatement returns [CreateColumnFamilyStatement.RawStatement expr]
    : K_CREATE K_COLUMNFAMILY cf=columnFamilyName { $expr = new CreateColumnFamilyStatement.RawStatement(cf); }
      cfamDefinition[expr]
    ;

cfamDefinition[CreateColumnFamilyStatement.RawStatement expr]
    : '(' cfamColumns[expr] ( ',' cfamColumns[expr]? )* ')'
      ( K_WITH cfamProperty[expr] ( K_AND cfamProperty[expr] )*)?
    ;

cfamColumns[CreateColumnFamilyStatement.RawStatement expr]
    : k=cident v=comparatorType { $expr.addDefinition(k, v); } (K_PRIMARY K_KEY { $expr.addKeyAliases(Collections.singletonList(k)); })?
    | K_PRIMARY K_KEY '(' pkDef[expr] (',' c=cident { $expr.addColumnAlias(c); } )* ')'
    ;

pkDef[CreateColumnFamilyStatement.RawStatement expr]
    : k=cident { $expr.addKeyAliases(Collections.singletonList(k)); }
    | '(' { List<ColumnIdentifier> l = new ArrayList<ColumnIdentifier>(); } k1=cident { l.add(k1); } ( ',' kn=cident { l.add(kn); } )* ')' { $expr.addKeyAliases(l); }
    ;

cfamProperty[CreateColumnFamilyStatement.RawStatement expr]
    : property[expr.properties]
    | K_COMPACT K_STORAGE { $expr.setCompactStorage(); }
    | K_CLUSTERING K_ORDER K_BY '(' cfamOrdering[expr] (',' cfamOrdering[expr])* ')'
    ;

cfamOrdering[CreateColumnFamilyStatement.RawStatement expr]
    @init{ boolean reversed=false; }
    : k=cident (K_ASC | K_DESC { reversed=true;} ) { $expr.setOrdering(k, reversed); }
    ;

/**
 * CREATE INDEX [indexName] ON columnFamily (columnName);
 */
createIndexStatement returns [CreateIndexStatement expr]
    : K_CREATE K_INDEX (idxName=IDENT)? K_ON cf=columnFamilyName '(' id=cident ')'
      { $expr = new CreateIndexStatement(cf, $idxName.text, id); }
    ;

/**
 * ALTER KEYSPACE <KS> WITH <property> = <value>;
 */
alterKeyspaceStatement returns [AlterKeyspaceStatement expr]
    @init { KSPropDefs attrs = new KSPropDefs(); }
    : K_ALTER K_KEYSPACE ks=keyspaceName
        K_WITH properties[attrs] { $expr = new AlterKeyspaceStatement(ks, attrs); }
    ;


/**
 * ALTER COLUMN FAMILY <CF> ALTER <column> TYPE <newtype>;
 * ALTER COLUMN FAMILY <CF> ADD <column> <newtype>;
 * ALTER COLUMN FAMILY <CF> DROP <column>;
 * ALTER COLUMN FAMILY <CF> WITH <property> = <value>;
 * ALTER COLUMN FAMILY <CF> RENAME <column> TO <column>;
 */
alterTableStatement returns [AlterTableStatement expr]
    @init {
        AlterTableStatement.Type type = null;
        CFPropDefs props = new CFPropDefs();
        Map<ColumnIdentifier, ColumnIdentifier> renames = new HashMap<ColumnIdentifier, ColumnIdentifier>();
    }
    : K_ALTER K_COLUMNFAMILY cf=columnFamilyName
          ( K_ALTER id=cident K_TYPE v=comparatorType { type = AlterTableStatement.Type.ALTER; }
          | K_ADD   id=cident v=comparatorType        { type = AlterTableStatement.Type.ADD; }
          | K_DROP  id=cident                         { type = AlterTableStatement.Type.DROP; }
          | K_WITH  properties[props]                 { type = AlterTableStatement.Type.OPTS; }
          | K_RENAME                                  { type = AlterTableStatement.Type.RENAME; }
               id1=cident K_TO toId1=cident { renames.put(id1, toId1); }
               ( K_AND idn=cident K_TO toIdn=cident { renames.put(idn, toIdn); } )*
          )
    {
        $expr = new AlterTableStatement(cf, type, id, v, props, renames);
    }
    ;

/**
 * DROP KEYSPACE <KSP>;
 */
dropKeyspaceStatement returns [DropKeyspaceStatement ksp]
    : K_DROP K_KEYSPACE ks=keyspaceName { $ksp = new DropKeyspaceStatement(ks); }
    ;

/**
 * DROP COLUMNFAMILY <CF>;
 */
dropColumnFamilyStatement returns [DropColumnFamilyStatement stmt]
    : K_DROP K_COLUMNFAMILY cf=columnFamilyName { $stmt = new DropColumnFamilyStatement(cf); }
    ;

/**
 * DROP INDEX <INDEX_NAME>
 */
dropIndexStatement returns [DropIndexStatement expr]
    :
      K_DROP K_INDEX index=IDENT
      { $expr = new DropIndexStatement($index.text); }
    ;

/**
  * TRUNCATE <CF>;
  */
truncateStatement returns [TruncateStatement stmt]
    : K_TRUNCATE cf=columnFamilyName { $stmt = new TruncateStatement(cf); }
    ;

/**
 * GRANT <permission> ON <resource> TO <username> [WITH GRANT OPTION]
 */
grantStatement returns [GrantStatement stmt]
    @init { boolean withGrant = false; }
    : K_GRANT
          permission
      K_ON
          resource=columnFamilyName
      K_TO
          user=(IDENT | STRING_LITERAL)
      (K_WITH K_GRANT K_OPTION { withGrant = true; })?
      {
        $stmt = new GrantStatement($permission.perm,
                                   resource,
                                   $user.text,
                                   withGrant);
      }
    ;

/**
 * REVOKE <permission> ON <resource> FROM <username>
 */
revokeStatement returns [RevokeStatement stmt]
    : K_REVOKE
        permission
      K_ON
        resource=columnFamilyName
      K_FROM
        user=(IDENT | STRING_LITERAL)
      {
        $stmt = new RevokeStatement($permission.perm,
                                    $user.text,
                                    resource);
      }
    ;

listGrantsStatement returns [ListGrantsStatement stmt]
    : K_LIST K_GRANTS K_FOR username=(IDENT | STRING_LITERAL) { $stmt = new ListGrantsStatement($username.text); }
    ;

permission returns [Permission perm]
    : p=(K_DESCRIBE | K_USE | K_CREATE | K_ALTER | K_DROP | K_SELECT | K_INSERT | K_UPDATE | K_DELETE | K_FULL_ACCESS | K_NO_ACCESS)
    { $perm = Permission.valueOf($p.text.toUpperCase()); }
    ;
/** DEFINITIONS **/

// Column Identifiers
cident returns [ColumnIdentifier id]
    : t=IDENT              { $id = new ColumnIdentifier($t.text, false); }
    | t=QUOTED_NAME        { $id = new ColumnIdentifier($t.text, true); }
    | k=unreserved_keyword { $id = new ColumnIdentifier(k, false); }
    ;

// Keyspace & Column family names
keyspaceName returns [String id]
    @init { CFName name = new CFName(); }
    : cfOrKsName[name, true] { $id = name.getKeyspace(); }
    ;

columnFamilyName returns [CFName name]
    @init { $name = new CFName(); }
    : (cfOrKsName[name, true] '.')? cfOrKsName[name, false]
    ;

cfOrKsName[CFName name, boolean isKs]
    : t=IDENT              { if (isKs) $name.setKeyspace($t.text, false); else $name.setColumnFamily($t.text, false); }
    | t=QUOTED_NAME        { if (isKs) $name.setKeyspace($t.text, true); else $name.setColumnFamily($t.text, true); }
    | k=unreserved_keyword { if (isKs) $name.setKeyspace(k, false); else $name.setColumnFamily(k, false); }
    ;

set_operation returns [Operation op]
    : t=term         { $op = ColumnOperation.Set(t); }
    | m=map_literal  { $op = MapOperation.Set(m);  }
    | l=list_literal { $op = ListOperation.Set(l); }
    | s=set_literal  { $op = SetOperation.Set(s);  }
    ;

list_literal returns [List<Term> value]
    : '[' { List<Term> l = new ArrayList<Term>(); } ( t1=term { l.add(t1); } ( ',' tn=term { l.add(tn); } )* )? ']' { $value = l; }
    ;

set_literal returns [List<Term> value]
    : '{' { List<Term> s = new ArrayList<Term>(); } ( t1=term { s.add(t1); } ( ',' tn=term { s.add(tn); } )* )? '}'  { $value = s; }
    ;

map_literal returns [Map<Term, Term> value]
    // Note that we have an ambiguity between maps and set for "{}". So we force it to a set, and deal with it later based on the type of the column
    : '{' { Map<Term, Term> m = new HashMap<Term, Term>(); }
          k1=term ':' v1=term { m.put(k1, v1); } ( ',' kn=term ':' vn=term { m.put(kn, vn); } )* '}'
       { $value = m; }
    ;

term returns [Term term]
    : t=(STRING_LITERAL | UUID | INTEGER | FLOAT | K_TRUE | K_FALSE ) { $term = new Term($t.text, $t.type); }
    | t=QMARK                                      { $term = new Term($t.text, $t.type, ++currentBindMarkerIdx); }
    ;

intTerm returns [Term integer]
    : t=INTEGER { $integer = new Term($t.text, $t.type); }
    | t=QMARK   { $integer = new Term($t.text, $t.type, ++currentBindMarkerIdx); }
    ;

termPairWithOperation[List<Pair<ColumnIdentifier, Operation>> columns]
    : key=cident '='
        (set_op = set_operation { columns.add(Pair.<ColumnIdentifier, Operation>create(key, set_op)); }
        | c=cident op=operation
          {
              if (!key.equals(c))
                  addRecognitionError("Only expressions like X = X <op> <value> are supported.");
              columns.add(Pair.<ColumnIdentifier, Operation>create(key, op));
          }
        | ll=list_literal '+' c=cident
          {
              if (!key.equals(c))
                  addRecognitionError("Only expressions like X = <value> + X are supported.");
              columns.add(Pair.<ColumnIdentifier, Operation>create(key, ListOperation.Prepend(ll)));
          }
        )
    | key=cident '[' t=term ']' '=' vv=term
      {
          Operation setOp = (t.getType() == Term.Type.INTEGER)
                             ? ListOperation.SetIndex(Arrays.asList(t, vv))
                             : MapOperation.Put(t, vv);

          columns.add(Pair.<ColumnIdentifier, Operation>create(key, setOp));
      }
    ;

operation returns [Operation op]
    : '+' v=intTerm { $op = ColumnOperation.CounterInc(v); }
    | sign='-'? v=intTerm
      {
          validateMinusSupplied(sign, v, input);
          if (sign == null)
              v = new Term(-(Long.valueOf(v.getText())), v.getType());
          $op = ColumnOperation.CounterDec(v);
      }
    | '+' ll=list_literal { $op = ListOperation.Append(ll); }
    | '-' ll=list_literal { $op = ListOperation.Discard(ll); }

    | '+' sl=set_literal { $op = SetOperation.Add(sl); }
    | '-' sl=set_literal { $op = SetOperation.Discard(sl); }

    | '+' ml=map_literal { $op = MapOperation.Put(ml); }
    ;

properties[PropertyDefinitions props]
    : property[props] (K_AND property[props])*
    ;

property[PropertyDefinitions props]
    : k=cident '=' (simple=propertyValue { try { $props.addProperty(k.toString(), simple); } catch (SyntaxException e) { addRecognitionError(e.getMessage()); } }
                   |   map=map_literal   { try { $props.addProperty(k.toString(), convertMap(map)); } catch (SyntaxException e) { addRecognitionError(e.getMessage()); } })
    ;

propertyValue returns [String str]
    : v=(STRING_LITERAL | IDENT | INTEGER | FLOAT | K_TRUE | K_FALSE) { $str = $v.text; }
    | u=unreserved_keyword                         { $str = u; }
    ;

// Either a string or a list of terms
tokenDefinition returns [Pair<String, List<Term>> tkdef]
    : K_TOKEN { List<Term> l = new ArrayList<Term>(); }
         '(' t1=term { l.add(t1); } ( ',' tn=term { l.add(tn); } )*  ')' { $tkdef = Pair.<String, List<Term>>create(null, l); }
    | t=STRING_LITERAL { $tkdef = Pair.<String, List<Term>>create($t.text, null); }
    ;

relation[List<Relation> clauses]
    : name=cident type=('=' | '<' | '<=' | '>=' | '>') t=term { $clauses.add(new Relation($name.id, $type.text, $t.term)); }
    | K_TOKEN { List<ColumnIdentifier> l = new ArrayList<ColumnIdentifier>(); }
       '(' name1=cident { l.add(name1); } ( ',' namen=cident { l.add(namen); })* ')'
           type=('=' |'<' | '<=' | '>=' | '>') tkd=tokenDefinition
       {
           if (tkd.right != null && tkd.right.size() != l.size())
           {
               addRecognitionError("The number of arguments to the token() function don't match");
           }
           else
           {
               Term str = tkd.left == null ? null : new Term(tkd.left, Term.Type.STRING);
               for (int i = 0; i < l.size(); i++)
               {
                   Term tt = str == null ? Term.tokenOf(tkd.right.get(i)) : str;
                   $clauses.add(new Relation(l.get(i), $type.text, tt, true));
               }
           }
       }
    | name=cident K_IN { Relation rel = Relation.createInRelation($name.id); }
       '(' f1=term { rel.addInValue(f1); } (',' fN=term { rel.addInValue(fN); } )* ')' { $clauses.add(rel); }
    ;

comparatorType returns [ParsedType t]
    : c=native_type     { $t = c; }
    | c=collection_type { $t = c; }
    | s=STRING_LITERAL
      {
        try {
            $t = new ParsedType.Custom($s.text);
        } catch (SyntaxException e) {
            addRecognitionError("Cannot parse type " + $s.text + ": " + e.getMessage());
        } catch (ConfigurationException e) {
            addRecognitionError("Errot setting type " + $s.text + ": " + e.getMessage());
        }
      }
    ;

native_type returns [ParsedType t]
    : K_ASCII     { $t = ParsedType.Native.ASCII; }
    | K_BIGINT    { $t = ParsedType.Native.BIGINT; }
    | K_BLOB      { $t = ParsedType.Native.BLOB; }
    | K_BOOLEAN   { $t = ParsedType.Native.BOOLEAN; }
    | K_COUNTER   { $t = ParsedType.Native.COUNTER; }
    | K_DECIMAL   { $t = ParsedType.Native.DECIMAL; }
    | K_DOUBLE    { $t = ParsedType.Native.DOUBLE; }
    | K_FLOAT     { $t = ParsedType.Native.FLOAT; }
    | K_INET      { $t = ParsedType.Native.INET;}
    | K_INT       { $t = ParsedType.Native.INT; }
    | K_TEXT      { $t = ParsedType.Native.TEXT; }
    | K_TIMESTAMP { $t = ParsedType.Native.TIMESTAMP; }
    | K_UUID      { $t = ParsedType.Native.UUID; }
    | K_VARCHAR   { $t = ParsedType.Native.VARCHAR; }
    | K_VARINT    { $t = ParsedType.Native.VARINT; }
    | K_TIMEUUID  { $t = ParsedType.Native.TIMEUUID; }
    ;

collection_type returns [ParsedType pt]
    : K_MAP  '<' t1=comparatorType ',' t2=comparatorType '>'
        { try { $pt = ParsedType.Collection.map(t1, t2); } catch (InvalidRequestException e) { addRecognitionError(e.getMessage()); } }
    | K_LIST '<' t=comparatorType '>'
        { try { $pt = ParsedType.Collection.list(t); } catch (InvalidRequestException e) { addRecognitionError(e.getMessage()); } }
    | K_SET  '<' t=comparatorType '>'
        { try { $pt = ParsedType.Collection.set(t); } catch (InvalidRequestException e) { addRecognitionError(e.getMessage()); } }
    ;

unreserved_keyword returns [String str]
    : k=( K_KEY
        | K_CLUSTERING
        | K_LEVEL
        | K_COUNT
        | K_TTL
        | K_COMPACT
        | K_STORAGE
        | K_TYPE
        | K_VALUES
        | K_WRITETIME
        | K_MAP
        | K_LIST
        ) { $str = $k.text; }
    | t=native_type { $str = t.toString(); }
    ;


// Case-insensitive keywords
K_SELECT:      S E L E C T;
K_FROM:        F R O M;
K_WHERE:       W H E R E;
K_AND:         A N D;
K_KEY:         K E Y;
K_INSERT:      I N S E R T;
K_UPDATE:      U P D A T E;
K_WITH:        W I T H;
K_LIMIT:       L I M I T;
K_USING:       U S I N G;
K_LEVEL:       ( O N E
               | Q U O R U M
               | A L L
               | A N Y
               | L O C A L '_' Q U O R U M
               | E A C H '_' Q U O R U M
               | T W O
               | T H R E E
               )
               ;
K_USE:         U S E;
K_COUNT:       C O U N T;
K_SET:         S E T;
K_BEGIN:       B E G I N;
K_UNLOGGED:    U N L O G G E D;
K_BATCH:       B A T C H;
K_APPLY:       A P P L Y;
K_TRUNCATE:    T R U N C A T E;
K_DELETE:      D E L E T E;
K_IN:          I N;
K_CREATE:      C R E A T E;
K_KEYSPACE:    ( K E Y S P A C E
                 | S C H E M A );
K_COLUMNFAMILY:( C O L U M N F A M I L Y
                 | T A B L E );
K_INDEX:       I N D E X;
K_ON:          O N;
K_TO:          T O;
K_DROP:        D R O P;
K_PRIMARY:     P R I M A R Y;
K_INTO:        I N T O;
K_VALUES:      V A L U E S;
K_TIMESTAMP:   T I M E S T A M P;
K_TTL:         T T L;
K_ALTER:       A L T E R;
K_RENAME:      R E N A M E;
K_ADD:         A D D;
K_TYPE:        T Y P E;
K_COMPACT:     C O M P A C T;
K_STORAGE:     S T O R A G E;
K_ORDER:       O R D E R;
K_BY:          B Y;
K_ASC:         A S C;
K_DESC:        D E S C;
K_GRANT:       G R A N T;
K_GRANTS:      G R A N T S;
K_REVOKE:      R E V O K E;
K_OPTION:      O P T I O N;
K_DESCRIBE:    D E S C R I B E;
K_FOR:         F O R;
K_FULL_ACCESS: F U L L '_' A C C E S S;
K_NO_ACCESS:   N O '_' A C C E S S;


K_CLUSTERING:  C L U S T E R I N G;
K_ASCII:       A S C I I;
K_BIGINT:      B I G I N T;
K_BLOB:        B L O B;
K_BOOLEAN:     B O O L E A N;
K_COUNTER:     C O U N T E R;
K_DECIMAL:     D E C I M A L;
K_DOUBLE:      D O U B L E;
K_FLOAT:       F L O A T;
K_INET:        I N E T;
K_INT:         I N T;
K_TEXT:        T E X T;
K_UUID:        U U I D;
K_VARCHAR:     V A R C H A R;
K_VARINT:      V A R I N T;
K_TIMEUUID:    T I M E U U I D;
K_TOKEN:       T O K E N;
K_WRITETIME:   W R I T E T I M E;

K_MAP:         M A P;
K_LIST:        L I S T;

K_TRUE:        T R U E;
K_FALSE:       F A L S E;

// Case-insensitive alpha characters
fragment A: ('a'|'A');
fragment B: ('b'|'B');
fragment C: ('c'|'C');
fragment D: ('d'|'D');
fragment E: ('e'|'E');
fragment F: ('f'|'F');
fragment G: ('g'|'G');
fragment H: ('h'|'H');
fragment I: ('i'|'I');
fragment J: ('j'|'J');
fragment K: ('k'|'K');
fragment L: ('l'|'L');
fragment M: ('m'|'M');
fragment N: ('n'|'N');
fragment O: ('o'|'O');
fragment P: ('p'|'P');
fragment Q: ('q'|'Q');
fragment R: ('r'|'R');
fragment S: ('s'|'S');
fragment T: ('t'|'T');
fragment U: ('u'|'U');
fragment V: ('v'|'V');
fragment W: ('w'|'W');
fragment X: ('x'|'X');
fragment Y: ('y'|'Y');
fragment Z: ('z'|'Z');

STRING_LITERAL
    @init{ StringBuilder b = new StringBuilder(); }
    @after{ setText(b.toString()); }
    : '\'' (c=~('\'') { b.appendCodePoint(c);} | '\'' '\'' { b.appendCodePoint('\''); })* '\''
    ;

QUOTED_NAME
    @init{ StringBuilder b = new StringBuilder(); }
    @after{ setText(b.toString()); }
    : '\"' (c=~('\"') { b.appendCodePoint(c); } | '\"' '\"' { b.appendCodePoint('\"'); })* '\"'
    ;

fragment DIGIT
    : '0'..'9'
    ;

fragment LETTER
    : ('A'..'Z' | 'a'..'z')
    ;

fragment HEX
    : ('A'..'F' | 'a'..'f' | '0'..'9')
    ;

INTEGER
    : '-'? DIGIT+
    ;

QMARK
    : '?'
    ;

/*
 * Normally a lexer only emits one token at a time, but ours is tricked out
 * to support multiple (see @lexer::members near the top of the grammar).
 */
FLOAT
    : INTEGER '.' DIGIT*
    ;

IDENT
    : LETTER (LETTER | DIGIT | '_')*
    ;

UUID
    : HEX HEX HEX HEX HEX HEX HEX HEX '-'
      HEX HEX HEX HEX '-'
      HEX HEX HEX HEX '-'
      HEX HEX HEX HEX '-'
      HEX HEX HEX HEX HEX HEX HEX HEX HEX HEX HEX HEX
    ;

WS
    : (' ' | '\t' | '\n' | '\r')+ { $channel = HIDDEN; }
    ;

COMMENT
    : ('--' | '//') .* ('\n'|'\r') { $channel = HIDDEN; }
    ;

MULTILINE_COMMENT
    : '/*' .* '*/' { $channel = HIDDEN; }
    ;
