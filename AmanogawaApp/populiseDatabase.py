import sqlite3


def create_connection(db_file):
    """ create a database connection to the SQLite database
        specified by the db_file
    :param db_file: database file
    :return: Connection object or None
    """
    conn = None
    try:
        conn = sqlite3.connect(db_file)
    except sqlite3.Error as e:
        print(e)

    return conn


def query_wiki_api(api_link):
    """
    update priority, begin_date, and end date of a task
    :param api_link:
    :return: event datas
    """

    wiki_name           = None
    wiki_description    = None
    wiki_extract        = None
    wiki_link           = None

    return wiki_name, wiki_description, wiki_extract, wiki_link, api_link


def update_event(conn, api_link):
    """
    update priority, begin_date, and end date of a task
    :param conn:
    :param api_link:
    """

    sql = ''' UPDATE AmanogawaAPI_event
              SET name              = ?,
                  description       = ?,
                  extract           = ?,
                  wiki_link         = ?
              WHERE API_wiki_link   = ?'''

    cur = conn.cursor()
    cur.execute(sql, (query_wiki_api(api_link)))
    conn.commit()


def get_api_links(conn):
    cursor = conn.cursor()
    cursor.execute("""SELECT API_wiki_link from AmanogawaAPI_event""")
    return cursor.fetchall()


def main():
    database = "../db.sqlite3"

    # create a database connection
    conn = create_connection(database)
    with conn:
        for api_link in get_api_links(conn):
            if api_link:
                update_event(conn, api_link)


if __name__ == '__main__':
    main()
