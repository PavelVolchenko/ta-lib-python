'''
This file Copyright (c) 2013 Brian A Cappello <briancappello at gmail>
'''
import talib
from talib import func as func_c
from collections import OrderedDict

cimport numpy as np
cimport abstract_h as abstract
from common_c import _ta_check_success
from cython.operator cimport dereference as deref


class Function(object):
    ''' This is a pythonic wrapper around TALIB's abstract interface. It is
    intended to simplify using individual TALIB functions by providing a unified
    interface for setting/controlling input data, setting function parameters
    and retrieving results. Input data consists of a dict of numpy arrays, one
    array for each of open, high, low, close and volume. This can be set with
    the set_input_arrays() method. Which keyed array(s) are used as inputs when
    calling the function is controlled using the input_names property.

    This class gets initialized with a TALIB function name and optionally an
    input_arrays dict. It provides the following primary functions for setting
    inputs and retrieving results:

    ---- input_array/TA-function-parameter set-only functions -----
    - set_input_arrays(input_arrays)
    - set_function_args([input_arrays,] [param_args_andor_kwargs])

    Documentation for param_args_andor_kwargs can be printed with print_help()
    or programatically via the info, input_names and parameters properties.

    ----- result-returning functions -----
    - the outputs property wraps a method which ensures results are always valid
    - run([input_arrays]) # calls set_input_arrays and returns self.outputs
    - FunctionInstance([input_arrays,] [param_args_andor_kwargs]) # calls set_function_args and returns self.outputs
    '''

    def __init__(self, function_name, input_arrays=None):
        # make sure the function_name is valid and define all of our variables
        self.__name = function_name.upper()
        if self.__name not in talib.get_functions():
            raise Exception('%s not supported by TA-LIB.' % self.__name)
        self.__info = None
        self.__input_arrays = { 'open': None,
                               'high': None,
                               'low': None,
                               'close': None,
                               'volume': None }

        # dictionaries of function args. keys are input/opt_input/output parameter names
        self.__input_names = OrderedDict()
        self.__opt_inputs = OrderedDict()
        self.__outputs = OrderedDict()
        self.__outputs_valid = False

        # lookup for TALIB input parameters which don't define expected price series inputs
        self.__input_price_series_defaults = { 'price': 'close',
                                               'price0': 'high',
                                               'price1': 'low',
                                               'periods': None } # only used by MAVP; not a price series!

        # finally query the TALIB abstract interface for the details of our function
        self.__initialize_private_variables()
        if input_arrays:
            self.set_input_arrays(input_arrays)

    def __initialize_private_variables(self):
        # function info
        self.__info = _ta_getFuncInfo(self.__name)

        # inputs (price series names)
        for i in xrange(self.__info.pop('num_inputs')):
            info = _ta_getInputParameterInfo(self.__name, i)
            input_name = info['name']
            if info['price_series'] == None:
                info['price_series'] = self.__input_price_series_defaults[input_name]
            self.__input_names[input_name] = info
        self.__info['input_names'] = self.input_names

        # optional inputs (function parameters)
        for i in xrange(self.__info.pop('num_opt_inputs')):
            info = _ta_getOptInputParameterInfo(self.__name, i)
            param_name = info['name']
            self.__opt_inputs[param_name] = info
        self.__info['parameters'] = self.parameters

        # outputs
        for i in xrange(self.__info.pop('num_outputs')):
            info = _ta_getOutputParameterInfo(self.__name, i)
            output_name = info['name']
            self.__outputs[output_name] = None
        self.__info['output_names'] = self.output_names

    def print_help(self):
        ''' Prints the function info documentation.
        '''
        defaults, docs = _get_defaults_and_docs(self.__info)
        print docs

    @property
    def info(self):
        ''' Returns a copy of the function's info dict.
        '''
        return self.__info.copy()

    @property
    def input_names(self):
        ''' Returns the dict of input price series names that specifies which
        of the ndarrays in input_arrays will be used to calculate the function.
        '''
        ret = OrderedDict()
        for input_name in self.__input_names:
            ret[input_name] = self.__input_names[input_name]['price_series']
        return ret

    @input_names.setter
    def set_input_names(self, input_names):
        ''' Sets the input price series names to use.
        '''
        for input_name, price_series in input_names.items():
            self.__input_names[input_name]['price_series'] = price_series
        self.__outputs_valid = False

    def get_input_arrays(self):
        ''' Returns a copy of the dict of input arrays in use.
        '''
        return self.__input_arrays.copy()

    def set_input_arrays(self, input_arrays):
        ''' Sets the dict of input_arrays to use. Returns True/False for subclasses:

        If input_arrays is a dict with the keys open, high, low, close and volume,
        it is assigned as the input_array to use and this function returns True,
        returning False otherwise. If you implement your own data type and wish
        to subclass Function, you should wrap this function with an if-statement:

        class CustomFunction(abstract.Function):
            def __init__(self, function_name):
                abstract.Function.__init__(self, function_name)

            def set_input_arrays(self, input_data):
                if abstract.Function.set_input_arrays(self, input_data):
                    return True
                elif isinstance(input_data, some_module.CustomDataType):
                    input_arrays = abstract.Function.get_input_arrays(self)
                    # convert input_data to input_arrays and then call the super
                    abstract.Function.set_input_arrays(self, input_arrays)
                    return True
                return False
        '''
        if isinstance(input_arrays, dict) \
          and sorted(input_arrays.keys()) == ['close', 'high', 'low', 'open', 'volume']:
            self.__input_arrays = input_arrays
            self.__outputs_valid = False
            return True
        return False

    @property
    def parameters(self):
        ''' Returns the function's optional parameters and their default values.
        '''
        ret = OrderedDict()
        for opt_input in self.__opt_inputs:
            ret[opt_input] = self.__get_opt_input_value(opt_input)
        return ret

    @parameters.setter
    def set_parameters(self, parameters):
        ''' Sets the function parameter values.
        '''
        for param, value in parameters.items():
            self.__opt_inputs[param]['value'] = value
        self.__outputs_valid = False
        self.__info['parameters'] = self.parameters

    def set_function_args(self, *args, **kwargs):
        ''' optionl args:[input_arrays,] [parameter_args,] [input_price_series_kwargs,] [parameter_kwargs]
        '''
        update_info = False
        if args:
            skip_first = 0
            if self.set_input_arrays(args[0]):
                skip_first = 1
            for i, param_name in enumerate(self.__opt_inputs):
                i += skip_first
                if i < len(args):
                    value = args[i]
                    self.__opt_inputs[param_name]['value'] = value
                    update_info = True

        for key in kwargs:
            if key in self.__opt_inputs:
                self.__opt_inputs[key]['value'] = kwargs[key]
                update_info = True
            elif key in self.__input_names:
                self.__input_names[key]['price_series'] = kwargs[key]

        if args or kwargs:
            if update_info:
                self.__info['parameters'] = self.parameters
            self.__outputs_valid = False

    @property
    def lookback(self):
        ''' Returns the lookback window size for the function with the parameter
        values that are currently set.
        '''
        cdef abstract.TA_ParamHolder *holder = __ta_paramHolderAlloc(self.__name)
        for i, opt_input in enumerate(self.__opt_inputs):
            value = self.__get_opt_input_value(opt_input)
            type_ = self.__opt_inputs[opt_input]['type']
            if type_ == abstract.TA_OptInput_RealRange or type_ == abstract.TA_OptInput_RealList:
                __ta_setOptInputParamReal(holder, i, value)
            elif type_ == abstract.TA_OptInput_IntegerRange or type_ == abstract.TA_OptInput_IntegerList:
                __ta_setOptInputParamInteger(holder, i, value)

        lookback = __ta_getLookback(holder)
        __ta_paramHolderFree(holder)
        return lookback

    @property
    def output_names(self):
        ''' Returns a list of the output names returned by this function.
        '''
        return self.__outputs.keys()

    @property
    def outputs(self):
        ''' Returns the TA function values for the currently set input_arrays
        and parameters. Returned values are a ndarray if there is only one
        output or a list of ndarrays for more than one output.
        '''
        if not self.__outputs_valid:
            self.__call_function()
        ret = self.__outputs.values()
        if len(ret) == 1:
            return ret[0]
        return ret

    def run(self, input_arrays=None):
        ''' A shortcut to the outputs property that also allows setting the
        input_arrays dict.
        '''
        if input_arrays:
            self.set_input_arrays(input_arrays)
        self.__call_function()
        return self.outputs

    def __call__(self, *args, **kwargs):
        ''' A shortcut to the outputs property that also allows setting the
        input_arrays dict and function parameters.
        '''
        self.set_function_args(*args, **kwargs)
        self.__call_function()
        return self.outputs

    def __call_function(self):
        # figure out which price series names we're using for inputs
        input_price_series_names = []
        for input_name in self.__input_names:
            price_series = self.__input_names[input_name]['price_series']
            if isinstance(price_series, list): # TALIB-supplied input names
                for name in price_series:
                    input_price_series_names.append(name)
            else: # name came from self.__input_price_series_defaults
                input_price_series_names.append(price_series)

        # populate the ordered args we'll call the function with
        args = []
        for price_series in input_price_series_names:
            args.append( self.__input_arrays[price_series] )
        for opt_input in self.__opt_inputs:
            value = self.__get_opt_input_value(opt_input)
            args.append(value)

        # Use the func module to actually call the function.
        results = func_c.__getattribute__(self.__name)(*args)
        if isinstance(results, np.ndarray):
            self.__outputs[self.__outputs.keys()[0]] = results
        else:
            for i, output in enumerate(self.__outputs):
                self.__outputs[output] = results[i]
        self.__outputs_valid = True

    def __get_opt_input_value(self, input_name):
        ''' Returns the user-set value if there is one, otherwise the default.
        '''
        value = self.__opt_inputs[input_name]['value']
        if not value:
            value = self.__opt_inputs[input_name]['default_value']
        return value


######################  INTERNAL python-level functions  #######################
'''
These map 1-1 with native C TALIB abstract interface calls. Their names are the
same except for having the leading 4 characters lowercased (and the Alloc/Free
function pairs which have been combined into single get functions)

These are TA function information-discovery calls. The Function class encapsulates
these functions into an easy-to-use, pythonic interface. It's therefore recommended
over using these functions directly.
'''

def _ta_getGroupTable():
    ''' Returns the list of available TALIB function group names.
    '''
    cdef abstract.TA_StringTable *table
    _ta_check_success('TA_GroupTableAlloc', abstract.TA_GroupTableAlloc(&table))
    groups = []
    for i in xrange(table.size):
        groups.append(deref(&table.string[i]))
    _ta_check_success('TA_GroupTableFree', abstract.TA_GroupTableFree(table))
    return groups

def _ta_getFuncTable(char *group):
    ''' Returns a list of the functions for the specified group name.
    '''
    cdef abstract.TA_StringTable *table
    _ta_check_success('TA_FuncTableAlloc', abstract.TA_FuncTableAlloc(group, &table))
    functions = []
    for i in xrange(table.size):
        functions.append(deref(&table.string[i]))
    _ta_check_success('TA_FuncTableFree', abstract.TA_FuncTableFree(table))
    return functions

def __get_flags(flag, flags_lookup_dict):
    ''' TA-LIB provides hints for multiple flags as a bitwise-ORed int. This
    function returns the flags from flag found in the provided flags_lookup_dict.
    '''
    # if the flag we got is out-of-range, it just means no extra info provided
    if flag < 1 or flag > 2**len(flags_lookup_dict)-1:
        return None

    # In this loop, i is essentially the bit-position, which represents an
    # input from flags_lookup_dict. We loop through as many flags_lookup_dict
    # bit-positions as we need to check, bitwise-ANDing each with flag for a hit.
    ret = []
    for i in xrange(len(flags_lookup_dict)):
        if 2**i & flag:
            ret.append(flags_lookup_dict[2**i])
    return ret

def _ta_getFuncInfo(char *function_name):
    ''' Returns the info dict for the function. It has the following keys: name,
    group, help, flags, num_inputs, num_opt_inputs and num_outputs.
    '''
    cdef abstract.TA_FuncInfo *info
    retCode = abstract.TA_GetFuncInfo(__ta_getFuncHandle(function_name), &info)
    _ta_check_success('TA_GetFuncInfo', retCode)

    ta_func_flags = { 16777216: 'Output scale same as input',
                      67108864: 'Output is over volume',
                      134217728: 'Function has an unstable period',
                      268435456: 'Output is a candlestick' }

    ret = { 'name': info.name,
            'group': info.group,
            'display_name': info.hint,
            'flags': __get_flags(info.flags, ta_func_flags),
            'num_inputs': int(info.nbInput),
            'num_opt_inputs': int(info.nbOptInput),
            'num_outputs': int(info.nbOutput) }
    return ret

def _ta_getInputParameterInfo(char *function_name, int idx):
    ''' Returns the function's input info dict for the given index. It has two
    keys: name and flags.
    '''
    cdef abstract.TA_InputParameterInfo *info
    retCode = abstract.TA_GetInputParameterInfo(__ta_getFuncHandle(function_name), idx, &info)
    _ta_check_success('TA_GetInputParameterInfo', retCode)

    # when flag is 0, the function (should) work on any reasonable input ndarray
    ta_input_flags = { 1: 'open',
                       2: 'high',
                       4: 'low',
                       8: 'close',
                       16: 'volumne',
                       32: 'openInterest',
                       64: 'timeStamp' }

    name = info.paramName
    name = name[len('in'):].lower()
    if 'real' in name:
        name = name.replace('real', 'price')
    elif 'price' in name:
        name = 'prices'

    ret = { 'name': name,
            #'type': info.type,
            'price_series': __get_flags(info.flags, ta_input_flags) }
    return ret

def _ta_getOptInputParameterInfo(char *function_name, int idx):
    ''' Returns the function's opt_input info dict for the given index. It has
    the following keys: name, display_name, type, help, default_value and value.
    '''
    cdef abstract.TA_OptInputParameterInfo *info
    retCode = abstract.TA_GetOptInputParameterInfo(__ta_getFuncHandle(function_name), idx, &info)
    _ta_check_success('TA_GetOptInputParameterInfo', retCode)

    name = info.paramName
    name = name[len('optIn'):].lower()
    default_value = info.defaultValue
    if default_value % 1 == 0:
        default_value = int(default_value)

    ret = { 'name': name,
            'display_name': info.displayName,
            'type': info.type,
            'help': info.hint,
            'default_value': default_value,
            'value': None }
    return ret

def _ta_getOutputParameterInfo(char *function_name, int idx):
    ''' Returns the function's output info dict for the given index. It has two
    keys: name and flags.
    '''
    cdef abstract.TA_OutputParameterInfo *info
    retCode = abstract.TA_GetOutputParameterInfo(__ta_getFuncHandle(function_name), idx, &info)
    _ta_check_success('TA_GetOutputParameterInfo', retCode)

    name = info.paramName
    name = name[len('out'):].lower()
    # chop off leading 'real' if a descriptive name follows
    if 'real' in name and name not in ['real', 'real0', 'real1']:
        name = name[len('real'):]

    ta_output_flags = { 1: 'Line',
                        2: 'Dotted Line',
                        4: 'Dashed Line',
                        8: 'Dot',
                        16: 'Histogram',
                        32: 'Pattern (Bool)',
                        64: 'Bull/Bear Pattern (Bearish < 0, Neutral = 0, Bullish > 0)',
                        128: 'Strength Pattern ([-200..-100] = Bearish, [-100..0] = Getting Bearish, 0 = Neutral, [0..100] = Getting Bullish, [100-200] = Bullish)',
                        256: 'Output can be positive',
                        512: 'Output can be negative',
                        1024: 'Output can be zero',
                        2048: 'Values represent an upper limit',
                        4096: 'Values represent a lower limit' }

    ret = { 'name': name,
            #'type': info.type,
            'description': __get_flags(info.flags, ta_output_flags) }
    return ret

def _get_defaults_and_docs(func_info):
    ''' Returns a tuple with two outputs: defaults, a dict of parameter defaults,
    and documentation, a formatted docstring for the function.
    .. Note: func_info should come from Function.info, *not* _ta_getFuncInfo.
    '''
    defaults = {}
    func_line = [func_info['name'], '(']
    func_args = ['[input_arrays]']
    docs = []
    docs.append('%(display_name)s (%(group)s)\n' % func_info)

    input_names = func_info['input_names']
    docs.append('Inputs:')
    for input_name in input_names:
        value = input_names[input_name]
        if not isinstance(value, list):
            value = '(any ndarray)'
        docs.append('    %s: %s' % (input_name, value))

    params = func_info['parameters']
    if params:
        docs.append('Parameters:')
    for param in params:
        docs.append('    %s: %s' % (param, params[param]))
        func_args.append('[%s=%s]' % (param, params[param]))
        defaults[param] = params[param]
        if param == 'matype':
            docs[-1] = ' '.join([docs[-1], '(%s)' % talib.MA_Type[params[param]]])

    outputs = func_info['output_names']
    docs.append('Outputs:')
    for output in outputs:
        if output == 'integer':
            output = 'integer (values are -100, 0 or 100)'
        docs.append('    %s' % output)

    func_line.append(', '.join(func_args))
    func_line.append(')\n')
    docs.insert(0, ''.join(func_line))
    documentation = '\n'.join(docs)
    return defaults, documentation


###############    PRIVATE C-level-only functions    ###########################
# These map 1-1 with native C TALIB abstract interface calls. Their names are the
# same except for having the leading 4 characters lowercased.

# These functions are for:
# - Gettinig TALIB handle and paramholder pointers
# - Setting TALIB paramholder optInput values and calling the lookback function

cdef abstract.TA_FuncHandle*  __ta_getFuncHandle(char *function_name):
    ''' Returns a pointer to a function handle for the given function name
    '''
    cdef abstract.TA_FuncHandle *handle
    _ta_check_success('TA_GetFuncHandle', abstract.TA_GetFuncHandle(function_name, &handle))
    return handle

cdef abstract.TA_ParamHolder* __ta_paramHolderAlloc(char *function_name):
    ''' Returns a pointer to a parameter holder for the given function name
    '''
    cdef abstract.TA_ParamHolder *holder
    retCode = abstract.TA_ParamHolderAlloc(__ta_getFuncHandle(function_name), &holder)
    _ta_check_success('TA_ParamHolderAlloc', retCode)
    return holder

cdef int __ta_paramHolderFree(abstract.TA_ParamHolder *params):
    ''' Frees the memory allocated by __ta_paramHolderAlloc (call when done with the parameter holder)
    WARNING: Not properly calling this function will cause memory leaks!
    '''
    _ta_check_success('TA_ParamHolderFree', abstract.TA_ParamHolderFree(params))

cdef int __ta_setOptInputParamInteger(abstract.TA_ParamHolder *holder, int idx, int value):
    retCode = abstract.TA_SetOptInputParamInteger(holder, idx, value)
    _ta_check_success('TA_SetOptInputParamInteger', retCode)

cdef int __ta_setOptInputParamReal(abstract.TA_ParamHolder *holder, int idx, int value):
    retCode = abstract.TA_SetOptInputParamReal(holder, idx, value)
    _ta_check_success('TA_SetOptInputParamReal', retCode)

cdef int __ta_getLookback(abstract.TA_ParamHolder *holder):
    cdef int lookback
    retCode = abstract.TA_GetLookback(holder, &lookback)
    _ta_check_success('TA_GetLookback', retCode)
    return lookback