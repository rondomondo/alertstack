#!/usr/bin/env python

import re
import os
import sys
try:
    import nltk
except ImportError as e:
    sys.stderr.write(f"import error {e} - perhaps run 'pip install nltk'\n")
    sys.exit(1)
    
# run this script wherever it is
pdir = os.path.dirname(sys.argv[0]) or "./"+os.path.dirname(sys.argv[0])
pname = os.path.basename(f"{re.sub('.py','',sys.argv[0])}")

os.chdir(pdir)

nltk.download('words')
nltk.download('wordnet')
nltk.download('webtext')

from nltk.corpus import words
from nltk.corpus import wordnet
from nltk.corpus import webtext
from collections import defaultdict
import sys
import select
import json
import pprint
import sys
  
# importing edit distance for the suggestions bit 
from nltk.metrics.distance  import edit_distance

from nltk.tokenize import word_tokenize

key_case_map = dict()

whitelistwords = "whitelistwords.csv"

camelcase_suspect = defaultdict(dict)
possible_misspellings = set()

def get_words_from_file(filename):
    with open(filename) as infile:
        data = infile.readlines()
        data = [w.strip() for w in data] 
        data = sorted(data)
        return data


def camelcase_split(splitme):
    splitted = re.sub('([A-Z][a-z]+)', r' \1', re.sub('([A-Z]+)', r' \1', splitme)).split()
    return splitted


def check_spelling(checkme):
    # Split on underscores and convert to lowercase
    key_split = re.sub("[_-]+"," ", checkme)
    lowercase_key_split = re.sub("[_-]+"," ", checkme).lower()

    # Split the key into individual words and save a mapping to the original case
    words_to_check = word_tokenize(key_split)
    words_to_check_lc = word_tokenize(lowercase_key_split)

    # save a camelcase split version if it matters
    for w in words_to_check:
        w_split = camelcase_split(w) 
        if len(w_split) > 1:
            camelcase_suspect[w] = w_split

    # maps of original word and case
    key_case_map.update(dict(list(zip(words_to_check_lc, words_to_check))))

    # Check for potential misspelled words
    misspelled_words = []
    for w in words_to_check_lc:
        if not wordnet.synsets(w):
            if w not in word_set:
                misspelled_words.append(w)
    return misspelled_words


def stdin_check():
    # see if anything to read on stdin - have we been piped input
    if select.select([sys.stdin, ], [], [], 0.0)[0]:
        # yes, something to read...
        sys.stderr.write("something to read from stdin\n")
        import fileinput
        data = fileinput.input()

        # parse the stdin - the prom node_exporter metric file
        data = [w.strip() for w in data] 
        #for w in lines_of_data:
        data = sorted(data)
        return data
    else:
        sys.stderr.write("nothing on stdin - have we a filename\n")
        return False


# see if we can suggest any fixes for bad spelling
def suggest_fixes(incorrect_words):
    suggest_dict = {}
    for word in incorrect_words:
        temp = [(edit_distance(word, w),w) for w in word_set if w[0]==word[0]]
        #print(f"suggest: in:{word}, poss:{sorted(temp, key = lambda val:val[0])[0][1]}")
        suggest_dict[word] = sorted(temp, key = lambda val:val[0])[0][1]
    return suggest_dict


# Iterate over the keys and check for suspect misspellings
def check_all_keys(keys):
    results = defaultdict(dict)
    for key in keys:
        misspelled_words = check_spelling(key)
        results[key] = {"misspelled": []}
        if misspelled_words:
            # global list of possibly misspelled words
            [possible_misspellings.add(w) for w in misspelled_words]
            results[key] = {"misspelled": misspelled_words}
    return dict(results)


# Load the NLTK words we want to try against
#word_set = set(wordnet.words()).union(set(words.words()))

word_set = set(webtext.words())

# add some of our own whitelisted words
[word_set.add(w) for w in get_words_from_file(whitelistwords)]

# much more words without much payoff - slower
word_set_large = set(webtext.words()).union(set(words.words()))

# the final suggested fixes and suspects goes here. this is what should be acted upon
suspect = defaultdict(dict)


def process(items_to_check):
    # check them for spelling issues
    check_result = check_all_keys(items_to_check)

    # for any possible issues suggest a fix
    suggested_fix_spelling_dict = suggest_fixes(possible_misspellings)
    
    # put any results into the suspect dict
    for k, v in check_result.items():
        misspelled = v.get('misspelled')
        # do we have anything that may be misspelled?
        if len(misspelled):
            # just the first for now
            possible_misspelled_word = misspelled.pop()

            # any suggestions for us?
            if possible_misspelled_word in suggested_fix_spelling_dict:
                suspect[k].update({"key": k,
                                    "check": possible_misspelled_word,
                                    "original": key_case_map.get(possible_misspelled_word),
                                    "suggestion": suggested_fix_spelling_dict.get(possible_misspelled_word)})
    return json.dumps(list(dict(suspect).values()))

# Example usage
# echo an identifier to the script...
# echo 'faLiures' | spellingcheck.py
#
# pipe the contents of a file to the script...
# cat somelistofidentifiers.csv | spellingcheck.py
#
# pass a filename to the script...
# cat somelistofidentifiers.csv | spellingcheck.py

if __name__ == "__main__":
    jvalues = ""
    try:
        # see if we have any piped input to stdin
        items_to_check = stdin_check()
        if items_to_check is not False:
            jvalues = process(items_to_check)
        else:
            if len(sys.argv) == 2:
                filename = sys.argv[1]

                # this could be a list of tag names, labels, annotations, config names etc....
                items_to_check = get_words_from_file(filename)
                
                # check them for spelling issues
                jvalues = process(items_to_check)
                #print(dict(camelcase_suspect)) 
    except Exception as e:
        pass

    # print any results
    print(jvalues)
